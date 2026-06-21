## Minecraft Server Container
# --- Server type + version ---
VERSION=26.1.2
FABRIC_LOADER_VERSION=0.19.3
EULA=TRUE
TYPE=FABRIC

# --- Memory ---
MEMORY=3G
USE_MEOWICE_FLAGS=false

# --- World ---
LEVEL=whymightacraft_season_001
SEED=

# --- Mods ---
MODRINTH_PROJECTS=fabric-api,lithium,krypton,ferrite-core,scalablelux,spark
REMOVE_OLD_MODS=true
MODRINTH_DOWNLOAD_DEPENDENCIES=required

# --- Server settings ---
DIFFICULTY=normal
MAX_PLAYERS=10
VIEW_DISTANCE=10
SIMULATION_DISTANCE=10
MOTD=§dHit the Rollie store with the Rollie on
SPAWN_PROTECTION=0
PLAYER_IDLE_TIMEOUT=0

# --- Whitelist ---
ENABLE_WHITELIST=true
ENFORCE_WHITELIST=true
EXISTING_WHITELIST_FILE=SYNC_FILE_MERGE_LIST
WHITELIST=ymjyta

# --- Ops ---
OPS=ymjyta
EXISTING_OPS_FILE=SYNC_FILE_MERGE_LIST

# --- Logging ---
ROLLING_LOG_MAX_FILES=20

# --- Shutdown ---
STOP_SERVER_ANNOUNCE_DELAY=30


## Minecraft Backup Container
BACKUP_METHOD=tar

RCON_HOST=minecraft
EXCLUDES=cache,libraries,versions,logs,*.jar,gc-logs

BACKUP_INTERVAL=24h
PRUNE_BACKUPS_DAYS=0
PRUNE_BACKUPS_COUNT=2
INITIAL_DELAY=0
