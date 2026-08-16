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
    },
    "modded.mc.whymighta.net": {
        "instance_id": "i-0e15703301b836de9",
        "region": "us-east-2",
    },
    "datapack.mc.whymighta.net": {
        "instance_id": "i-0b2d59b3e90a056ef",
        "region": "us-east-2",
    },
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


def start_instance_if_needed(instance_id: str, region: str, hostname: str) -> None:
    ec2 = boto3.client("ec2", region_name=region)

    resp  = ec2.describe_instances(InstanceIds=[instance_id])
    state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]

    if state in STARTABLE_STATES:
        logger.info(f"Starting instance {instance_id} for {hostname} (was: {state})")
        ec2.start_instances(InstanceIds=[instance_id])

    elif state in ALREADY_STARTING:
        logger.info(f"Instance {instance_id} for {hostname} already in state: {state} — nothing to do")

    elif state in TRANSITIONAL_STATES:
        logger.warning(f"Instance {instance_id} for {hostname} is in transitional state: {state} — skipping")

    else:
        logger.warning(f"Instance {instance_id} for {hostname} in unhandled state: {state}")


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
        start_instance_if_needed(server["instance_id"], server["region"], matched)

    return {"statusCode": 200, "body": json.dumps("done")}