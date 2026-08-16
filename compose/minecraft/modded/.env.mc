## Minecraft Server Container
# --- Server type + version ---
VERSION=1.20.1
EULA=TRUE
TYPE=AUTO_CURSEFORGE

# --- Memory ---
MEMORY=6G

# --- Modpack ---
CF_SLUG=cursed-walking-a-modern-zombie-apocalypse

# --- World ---
LEVEL=cursedwalking_season_001
SEED=

# --- Server settings ---
DIFFICULTY=normal
MAX_PLAYERS=10
VIEW_DISTANCE=8
SIMULATION_DISTANCE=8
MOTD=§cModded Survival Server
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
EXCLUDES=cache,libraries,versions,logs,*.jar,gc-logs,mods,config,kubejs

BACKUP_INTERVAL=24h
PRUNE_BACKUPS_DAYS=0
PRUNE_BACKUPS_COUNT=2
INITIAL_DELAY=0