import json
import gzip
import base64
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Map each Minecraft subdomain to its EC2 instance details.
# Add new servers here — no other code changes needed.
SERVER_MAP = {
    "vanilla.mc.whymighta.net": {
        "instance_id": "i-0d3dbe15ebefafdca",
        "region": "us-east-2",
        "hosted_zone_id": "Z04285551JOMKVII7XNDL",
    },
    # "modded.mc.whymighta.net": {
    #     "instance_id": "i-ANOTHER_INSTANCE_ID",
    #     "region": "us-east-2",
    #     "hosted_zone_id": "YOUR_HOSTED_ZONE_ID",
    # },
}

# States where we can call start_instances
STARTABLE_STATES  = {"stopped"}
# States where it's already coming up — do nothing
ALREADY_STARTING  = {"pending", "running"}
# States where we should warn but not act
TRANSITIONAL_STATES = {"stopping", "shutting-down"}


def decode_log_event(event: dict) -> list[str]:
    """
    Decodes the base64 + gzip CloudWatch Logs event payload
    and returns a list of raw log message strings.
    """
    compressed = base64.b64decode(event["awslogs"]["data"])
    decompressed = gzip.decompress(compressed)
    payload = json.loads(decompressed)
    return [e["message"] for e in payload.get("logEvents", [])]


def extract_queried_hostname(log_message: str) -> str | None:
    """
    Parses a Route53 query log line and returns the queried hostname.

    Route53 query log format:
      <version> <date> <hosted-zone-id> <hostname>. <record-type> <response> ...

    Only acts on SRV queries for _minecraft._tcp.<hostname> — this filters
    out browser A/AAAA lookups which would otherwise start the server
    spuriously when someone visits a URL.
    """
    parts = log_message.strip().split()
    if len(parts) < 5:
        return None

    hostname = parts[3].rstrip(".").lower()
    record_type = parts[4].upper()
    if record_type != "SRV":
        return None

    SRV_PREFIX = "_minecraft._tcp."
    if not hostname.startswith(SRV_PREFIX):
        return None

    return hostname.removeprefix(SRV_PREFIX)


def get_existing_eip(ec2, instance_id: str) -> str | None:
    """
    Returns the public IP if the instance already has an EIP associated,
    else None. Guards against double-allocation if the Lambda fires
    multiple times for the same CloudWatch log batch.
    """
    resp = ec2.describe_addresses(Filters=[{"Name": "instance-id", "Values": [instance_id]}])
    addresses = resp.get("Addresses", [])
    if addresses:
        return addresses[0]["PublicIp"]
    return None


def allocate_and_associate_eip(ec2, instance_id: str) -> str:
    """
    Allocates a fresh EIP and associates it with the (stopped) instance.
    EIPs can be associated with stopped instances — no need to wait for boot.
    Returns the public IP.
    """
    eip = ec2.allocate_address(Domain="vpc")
    allocation_id = eip["AllocationId"]
    public_ip = eip["PublicIp"]
    logger.info(f"Allocated EIP {public_ip} ({allocation_id})")

    ec2.associate_address(InstanceId=instance_id, AllocationId=allocation_id)
    logger.info(f"Associated EIP {allocation_id} with {instance_id}")

    return public_ip


def update_route53(hostname: str, hosted_zone_id: str, public_ip: str) -> None:
    """
    Updates the A record for hostname to point at public_ip.
    TTL is kept low (60s) since the IP changes on every boot.
    """
    r53 = boto3.client("route53")
    r53.change_resource_record_sets(
        HostedZoneId=hosted_zone_id,
        ChangeBatch={"Changes": [{
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": hostname,
                "Type": "A",
                "TTL": 60,
                "ResourceRecords": [{"Value": public_ip}],
            },
        }]},
    )
    logger.info(f"Route53 updated: {hostname} -> {public_ip}")


def start_instance_if_needed(instance_id: str, region: str, hostname: str, hosted_zone_id: str) -> None:
    ec2 = boto3.client("ec2", region_name=region)

    resp  = ec2.describe_instances(InstanceIds=[instance_id])
    state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]

    if state in ALREADY_STARTING:
        logger.info(f"Instance {instance_id} for {hostname} already in state: {state} — nothing to do")
        return

    if state in TRANSITIONAL_STATES:
        logger.warning(f"Instance {instance_id} for {hostname} is in transitional state: {state} — skipping")
        return

    if state not in STARTABLE_STATES:
        logger.warning(f"Instance {instance_id} for {hostname} in unhandled state: {state}")
        return
    
    # --- Start ---
    logger.info(f"Starting instance {instance_id} for {hostname} (was: {state})")
    ec2.start_instances(InstanceIds=[instance_id])

    # --- EIP ---
    # Allocate before starting so DNS is live while the instance boots.
    # Check for an existing EIP first in case of duplicate Lambda invocations
    # from the same CloudWatch log batch.
    public_ip = get_existing_eip(ec2, instance_id)
    if public_ip:
        logger.info(f"Instance {instance_id} already has EIP {public_ip} — reusing")
    else:
        public_ip = allocate_and_associate_eip(ec2, instance_id)

    # --- Route53 ---
    update_route53(hostname, hosted_zone_id, public_ip)


def lambda_handler(event: dict, context) -> dict:
    log_messages = decode_log_event(event)

    triggered_hostnames = set()

    for message in log_messages:
        hostname = extract_queried_hostname(message)
        if not hostname:
            continue

        # Match against known servers — exact match or subdomain match
        matched = None
        for known_hostname in SERVER_MAP:
            if hostname == known_hostname or hostname.endswith(f".{known_hostname}"):
                matched = known_hostname
                break

        if not matched:
            logger.info(f"No server mapping for hostname: {hostname} — ignoring")
            continue

        if matched in triggered_hostnames:
            # Multiple log lines can match the same server in one batch — only act once
            continue

        triggered_hostnames.add(matched)
        server = SERVER_MAP[matched]
        start_instance_if_needed(server["instance_id"], server["region"], matched, server["hosted_zone_id"])

    return {"statusCode": 200, "body": json.dumps("done")}