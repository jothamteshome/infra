import asyncio
import json
import time

from probes.minecraft import check_all_minecraft_servers
from probes.sites import check_all_sites
from probes.containers import get_container_stats

ALLOWED_ORIGINS = {
    "https://status.whymighta.net",
    "http://localhost:5173",
}


async def main(event: dict) -> dict:
    origin = (event.get("headers") or {}).get("origin", "")
    allow_origin = origin if origin in ALLOWED_ORIGINS else "https://status.whymighta.net"
    cors_headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": allow_origin,
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    }

    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return {"statusCode": 204, "headers": cors_headers, "body": ""}

    try:
        minecraft, checked, containers = await asyncio.gather(
            check_all_minecraft_servers(),
            check_all_sites(),
            get_container_stats(),
        )

        body = {
            "minecraft":   minecraft,
            "sites":       checked["sites"],
            "apis":        checked["apis"],
            "containers":  containers,
            "checked_at":  int(time.time()),
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "headers": cors_headers,
            "body": json.dumps({"error": str(e)}),
        }

    return {
        "statusCode": 200,
        "headers": cors_headers,
        "body": json.dumps(body),
    }


def lambda_handler(event: dict, context) -> dict:
    return asyncio.run(main(event))