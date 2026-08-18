## Minecraft Server Container
# --- Server type + version ---
VERSION=26.2
FABRIC_LOADER_VERSION=0.19.3
EULA=TRUE
TYPE=FABRIC

# --- Memory ---
MEMORY=6G
USE_MEOWICE_FLAGS=false

# --- World ---
LEVEL=moddedcraft_season_001
SEED=

# --- Mods + Datapacks (all via MODRINTH_PROJECTS) ---
# DATAPACKS var dropped - it doesn't support modrinth: slugs, only direct zip URLs
# Modrinth datapacks go in MODRINTH_PROJECTS alongside mods - itzg handles them correctly
# ScalableLux dropped - no 1.21.1 Fabric build
# fast-path dropped - abandoned at 1.16
# RPG Series deps pulled automatically via MODRINTH_DOWNLOAD_DEPENDENCIES=required
MODRINTH_PROJECTS=fabric-api,lithium,krypton,ferrite-core,dynamic-torches,explorify,vanilla-refresh,dungeons-and-taverns,neoenchant,tool-trims,infinity-cave:beta,svm-powers,incendium,nullscape,emotecraft:beta,ping-wheel,lgs-player-corpses
REMOVE_OLD_MODS=true
MODRINTH_DOWNLOAD_DEPENDENCIES=required

# --- Server settings ---
DIFFICULTY=normal
MAX_PLAYERS=10
VIEW_DISTANCE=10
SIMULATION_DISTANCE=10
MOTD=§dDatapack Survival Server
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