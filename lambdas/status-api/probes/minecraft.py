import asyncio
from mcstatus import JavaServer

MINECRAFT_SERVERS = [
    ("vanilla.mc.whymighta.net", "25565"),
    ("modded.mc.whymighta.net", "25565"),
]

STATUS_TIMEOUT = 3

async def check_minecraft_server(hostname: str, port: str) -> dict:
    try:
        server = JavaServer.lookup(f"{hostname}:{port}", timeout=STATUS_TIMEOUT)
        status = await server.async_status()
        return {
            "online": True,
            "players": {
                "online": status.players.online,
                "max": status.players.max,
                "sample": [p.name for p in (status.players.sample or [])],
            },
            "version": status.version.name,
            "motd": status.description,
            "latency": round(status.latency, 1),
        }
    except Exception as e:
        return {"online": False, "error": str(e)}


async def check_all_minecraft_servers() -> dict:
    results = await asyncio.gather(*[
        check_minecraft_server(hostname, port)
        for hostname, port in MINECRAFT_SERVERS
    ])
    return dict(zip([h for h, _ in MINECRAFT_SERVERS], results))