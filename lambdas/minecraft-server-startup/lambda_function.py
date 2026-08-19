import json
import logging
import boto3
import functools


logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Map each Minecraft server type to its EC2 instance details and subdomain.
# Add new servers here — no other code changes needed.
SERVER_MAP = {
    "vanilla": {
        "instance_id": "i-0d3dbe15ebefafdca",
        "region": "us-east-2",
        "hostname": "vanilla.mc.whymighta.net"
    },
    "modded": {
        "instance_id": "i-0e15703301b836de9",
        "region": "us-east-2",
        "hostname": "modded.mc.whymighta.net"
    },
    "datapack": {
        "instance_id": "i-0b2d59b3e90a056ef",
        "region": "us-east-2",
        "hostname": "datapack.mc.whymighta.net"
    },
}


STARTABLE_STATES  = {"stopped"}
ALREADY_STARTING  = {"pending", "running"}
TRANSITIONAL_STATES = {"stopping", "shutting-down"}


@functools.cache
def get_api_secret() -> str:
    ssm = boto3.client("ssm", region_name="us-east-2")
    return ssm.get_parameter(
        Name="/minecraft/api-secret",
        WithDecryption=True
    )["Parameter"]["Value"]


def get_instance_state(instance_id: str, region: str) -> str:
    ec2 = boto3.client("ec2", region_name=region)
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def get_all_statuses() -> dict:
    return {
        name: {"hostname": server["hostname"], "state": get_instance_state(server["instance_id"], server["region"])}
        for name, server in SERVER_MAP.items()
    }


def start_instance_if_needed(instance_id: str, region: str, hostname: str) -> dict:
    state = get_instance_state(instance_id, region)
    ec2 = boto3.client("ec2", region_name=region)

    if state in STARTABLE_STATES:
        logger.info(f"Starting instance {instance_id} for {hostname} (was: {state})")
        ec2.start_instances(InstanceIds=[instance_id])
        state = "starting"
    elif state in ALREADY_STARTING:
        logger.info(f"Instance {instance_id} for {hostname} already in state: {state} — nothing to do")
    elif state in TRANSITIONAL_STATES:
        logger.warning(f"Instance {instance_id} for {hostname} is in transitional state: {state} — skipping")
    else:
        logger.warning(f"Instance {instance_id} for {hostname} in unhandled state: {state}")

    return {"status": state, "hostname": hostname}


def response(status_code: int, body: dict) -> dict:
    return {"statusCode": status_code, "body": json.dumps(body)}


def handle_status(event: dict) -> dict:
    return response(200, get_all_statuses())


def handle_start(event: dict) -> dict:
    raw_body = event.get("body")
    logger.info(f"Raw body: {repr(raw_body)}")
    body = json.loads(raw_body or "{}")
    name = body.get("server", "").lower()

    if name not in SERVER_MAP:
        return response(400, {"error": f"Unknown server. Valid options: {list(SERVER_MAP.keys())}"})

    server = SERVER_MAP[name]
    return response(200, start_instance_if_needed(server["instance_id"], server["region"], server["hostname"]))


def handle_stop(event: dict) -> dict:
    raw_body = event.get("body")
    logger.info(f"Raw body: {repr(raw_body)}")
    body = json.loads(raw_body or "{}")
    name = body.get("server", "").lower()

    if name not in SERVER_MAP:
        return response(400, {"error": f"Unknown server. Valid options: {list(SERVER_MAP.keys())}"})

    server = SERVER_MAP[name]
    state = get_instance_state(server["instance_id"], server["region"])

    if state == "running":
        logger.info(f"Stopping instance {server['instance_id']} for {server['hostname']}")
        boto3.client("ec2", region_name=server["region"]).stop_instances(InstanceIds=[server["instance_id"]])
        return response(200, {"status": "stopping", "hostname": server["hostname"]})

    return response(200, {"status": state, "hostname": server["hostname"]})


ROUTES = {
    ("GET",  "/status"): handle_status,
    ("POST", "/start"):  handle_start,
    ("POST", "/stop"): handle_stop
}


def lambda_handler(event: dict, context) -> dict:
    if (event.get("headers") or {}).get("x-api-key") != get_api_secret():
        return response(401, {"error": "Unauthorized"})
    
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("rawPath", "")

    handler = ROUTES.get((method, path))

    if handler:
        return handler(event)

    return response(404, {"error": "Not found"})