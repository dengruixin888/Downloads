#!/usr/bin/env bash
# =============================================================================
# Sub2API one-shot backup, restore, and server-to-server migration helper.
#
# Run this script from your Sub2API Docker deployment directory, the directory
# that contains .env and docker-compose.yml / docker-compose.local.yml.
# =============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"

ACTION=""
COMPOSE_FILE=""
OUTPUT_FILE=""
TARGET_DIR=""
SSH_PORT=""
YES=false
NO_STOP=false
START_AFTER_RESTORE=false
FORCE_RESTORE=false
REMOTE_KEEP_ARCHIVE=false

usage() {
    printf '%s\n' \
        "Sub2API migration helper" \
        "" \
        "Usage:" \
        "  ./${SCRIPT_NAME} backup [options]" \
        "  ./${SCRIPT_NAME} restore <archive.tar.gz> [options]" \
        "  ./${SCRIPT_NAME} migrate <user@host:/target/dir> [options]" \
        "" \
        "Actions:" \
        "  backup      Stop services, package the current deployment and data." \
        "  restore     Restore a package on the target server." \
        "  migrate     Backup locally, upload to another server, restore and start there." \
        "" \
        "Options:" \
        "  -f, --compose-file FILE   Compose file to use. Auto-detected by default." \
        "  -o, --output FILE         Backup archive path. Default: ./sub2api-migration-<time>.tar.gz" \
        "  -t, --target-dir DIR      Restore target directory. Default: current directory." \
        "  -p, --ssh-port PORT       SSH port for migrate." \
        "  -y, --yes                 Do not ask for confirmation." \
        "      --no-stop             Do not stop source services during backup. Not recommended." \
        "      --start               Start services after restore." \
        "      --force               Allow restore into a non-empty target directory / volume." \
        "      --keep-remote-archive Keep uploaded archive on the remote server after migrate." \
        "  -h, --help                Show this help." \
        "" \
        "Examples:" \
        "  # Source server: create a local package" \
        "  ./${SCRIPT_NAME} backup --yes" \
        "" \
        "  # New server: restore and start" \
        "  ./${SCRIPT_NAME} restore sub2api-migration-20260708153000.tar.gz --target-dir /opt/sub2api --start --yes" \
        "" \
        "  # Source server: one-shot migration to a new server" \
        "  ./${SCRIPT_NAME} migrate root@203.0.113.10:/opt/sub2api --yes" \
        "" \
        "Notes:" \
        "  - Docker local-directory deployments package ./data, ./postgres_data and ./redis_data." \
        "  - Docker named-volume deployments package Docker volumes by inspecting the running containers." \
        "  - The source service stays stopped after migrate to avoid split-brain writes."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

confirm() {
    local prompt="$1"
    if [ "$YES" = true ]; then
        return 0
    fi
    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) fail "Cancelled" ;;
    esac
}

abs_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(pwd -P)" "$path"
    fi
}

safe_quote() {
    printf "%q" "$1"
}

detect_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
    else
        fail "Docker Compose is not available. Install docker compose plugin or docker-compose."
    fi
}

detect_compose_file() {
    if [ -n "$COMPOSE_FILE" ]; then
        [ -f "$COMPOSE_FILE" ] || fail "Compose file not found: $COMPOSE_FILE"
        return
    fi

    if [ -f docker-compose.local.yml ]; then
        COMPOSE_FILE="docker-compose.local.yml"
    elif [ -f docker-compose.yml ]; then
        COMPOSE_FILE="docker-compose.yml"
    elif [ -f compose.yml ]; then
        COMPOSE_FILE="compose.yml"
    else
        fail "No compose file found. Run from the Sub2API deployment directory."
    fi
}

compose() {
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"
}

compose_with_project() {
    local project_name="$1"
    shift
    if [ -n "$project_name" ]; then
        "${COMPOSE_CMD[@]}" -p "$project_name" -f "$COMPOSE_FILE" "$@"
    else
        "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"
    fi
}

deployment_dir() {
    local compose_abs
    compose_abs="$(abs_path "$COMPOSE_FILE")"
    dirname "$compose_abs"
}

detect_storage_mode() {
    if grep -Eq '^[[:space:]]*-[[:space:]]*\./[^:]+:/app/data(:|$)' "$COMPOSE_FILE" \
        || grep -Eq '^[[:space:]]*-[[:space:]]*\./[^:]+:/var/lib/postgresql/data(:|$)' "$COMPOSE_FILE" \
        || grep -Eq '^[[:space:]]*-[[:space:]]*\./[^:]+:/data(:|$)' "$COMPOSE_FILE"; then
        STORAGE_MODE="local"
    else
        STORAGE_MODE="named"
    fi
}

container_mount_volume() {
    local container="$1"
    local destination="$2"
    docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$destination"'"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' "$container" 2>/dev/null || true
}

compose_project_from_volume() {
    local volume="$1"
    docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$volume" 2>/dev/null || true
}

env_project_name() {
    local dir="$1"
    if [ -f "$dir/.env" ]; then
        sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$dir/.env" | tail -n 1 | tr -d '"' | tr -d "'"
    fi
}

default_project_name() {
    local dir="$1"
    local name
    name="$(basename "$dir")"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

volume_by_label() {
    local project="$1"
    local logical="$2"
    docker volume ls -q \
        --filter "label=com.docker.compose.project=$project" \
        --filter "label=com.docker.compose.volume=$logical" \
        | head -n 1
}

resolve_named_volumes() {
    local dir project
    dir="$(deployment_dir)"

    SUB2API_VOLUME="$(container_mount_volume sub2api /app/data)"
    POSTGRES_VOLUME="$(container_mount_volume sub2api-postgres /var/lib/postgresql/data)"
    REDIS_VOLUME="$(container_mount_volume sub2api-redis /data)"

    PROJECT_NAME=""
    if [ -n "${POSTGRES_VOLUME:-}" ]; then
        PROJECT_NAME="$(compose_project_from_volume "$POSTGRES_VOLUME")"
    fi
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$(env_project_name "$dir")"
    fi
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$(default_project_name "$dir")"
    fi

    if [ -z "${SUB2API_VOLUME:-}" ]; then SUB2API_VOLUME="$(volume_by_label "$PROJECT_NAME" sub2api_data)"; fi
    if [ -z "${POSTGRES_VOLUME:-}" ]; then POSTGRES_VOLUME="$(volume_by_label "$PROJECT_NAME" postgres_data)"; fi
    if [ -z "${REDIS_VOLUME:-}" ]; then REDIS_VOLUME="$(volume_by_label "$PROJECT_NAME" redis_data)"; fi

    [ -n "${SUB2API_VOLUME:-}" ] || fail "Cannot find sub2api_data volume. Start the stack once, or use local-directory deployment."
    [ -n "${POSTGRES_VOLUME:-}" ] || fail "Cannot find postgres_data volume. Start the stack once, or use local-directory deployment."
    [ -n "${REDIS_VOLUME:-}" ] || fail "Cannot find redis_data volume. Start the stack once, or use local-directory deployment."
}

write_manifest() {
    local manifest="$1"
    : > "$manifest"
    {
        echo "ARCHIVE_VERSION=1"
        echo "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "STORAGE_MODE=$(safe_quote "$STORAGE_MODE")"
        echo "COMPOSE_FILE=$(safe_quote "$(basename "$COMPOSE_FILE")")"
        echo "PROJECT_NAME=$(safe_quote "${PROJECT_NAME:-}")"
        echo "SUB2API_VOLUME=$(safe_quote "${SUB2API_VOLUME:-}")"
        echo "POSTGRES_VOLUME=$(safe_quote "${POSTGRES_VOLUME:-}")"
        echo "REDIS_VOLUME=$(safe_quote "${REDIS_VOLUME:-}")"
        echo "SOURCE_DIR=$(safe_quote "$(deployment_dir)")"
    } >> "$manifest"
}

tar_deployment_dir() {
    local dir="$1"
    local output="$2"

    tar \
        --exclude='./.git' \
        --exclude='./sub2api-migration-*.tar.gz' \
        -czf "$output" \
        -C "$dir" .
}

backup_volume() {
    local volume="$1"
    local output="$2"
    log "Packaging Docker volume $volume"
    docker run --rm \
        -v "$volume:/volume:ro" \
        -v "$(dirname "$output"):/backup" \
        alpine sh -c "cd /volume && tar czf /backup/$(basename "$output") ."
}

create_backup() {
    need_cmd docker
    need_cmd tar
    detect_compose_cmd
    detect_compose_file
    detect_storage_mode

    local dir staging output_abs timestamp
    dir="$(deployment_dir)"
    timestamp="$(date +%Y%m%d%H%M%S)"
    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="$dir/sub2api-migration-$timestamp.tar.gz"
    fi
    output_abs="$(abs_path "$OUTPUT_FILE")"

    log "Compose file: $COMPOSE_FILE"
    log "Storage mode: $STORAGE_MODE"

    if [ "$STORAGE_MODE" = "named" ]; then
        resolve_named_volumes
        log "Compose project: $PROJECT_NAME"
        log "Volumes: $SUB2API_VOLUME, $POSTGRES_VOLUME, $REDIS_VOLUME"
    else
        PROJECT_NAME="$(env_project_name "$dir")"
        if [ -z "$PROJECT_NAME" ]; then PROJECT_NAME="$(default_project_name "$dir")"; fi
    fi

    if [ "$NO_STOP" = false ]; then
        confirm "This will stop the source Sub2API stack before backup. Continue?"
        log "Stopping source stack"
        compose down
    else
        warn "Backing up without stopping services. PostgreSQL/Redis files may be inconsistent."
    fi

    staging="$(mktemp -d)"
    mkdir -p "$staging/volumes"

    write_manifest "$staging/manifest.env"
    log "Packaging deployment directory: $dir"
    tar_deployment_dir "$dir" "$staging/deployment.tar.gz"

    if [ "$STORAGE_MODE" = "named" ]; then
        backup_volume "$SUB2API_VOLUME" "$staging/volumes/sub2api_data.tar.gz"
        backup_volume "$POSTGRES_VOLUME" "$staging/volumes/postgres_data.tar.gz"
        backup_volume "$REDIS_VOLUME" "$staging/volumes/redis_data.tar.gz"
    fi

    tar czf "$output_abs" -C "$staging" .
    ok "Backup created: $output_abs"
    BACKUP_RESULT="$output_abs"
    rm -rf "$staging"
}

dir_is_empty() {
    local dir="$1"
    [ ! -d "$dir" ] && return 0
    [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

volume_is_empty() {
    local volume="$1"
    docker run --rm -v "$volume:/volume:ro" alpine sh -c '[ -z "$(find /volume -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]'
}

clear_volume() {
    local volume="$1"
    docker run --rm -v "$volume:/volume" alpine sh -c 'find /volume -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;'
}

restore_volume() {
    local volume="$1"
    local archive="$2"
    docker volume create "$volume" >/dev/null
    if ! volume_is_empty "$volume"; then
        [ "$FORCE_RESTORE" = true ] || fail "Docker volume $volume is not empty. Re-run with --force to overwrite it."
        warn "Clearing Docker volume $volume"
        clear_volume "$volume"
    fi
    log "Restoring Docker volume $volume"
    docker run --rm \
        -v "$volume:/volume" \
        -v "$(dirname "$archive"):/backup:ro" \
        alpine sh -c "cd /volume && tar xzf /backup/$(basename "$archive")"
}

prepare_target_dir() {
    local target="$1"
    [ -n "$target" ] || fail "Target directory is empty"
    [ "$target" != "/" ] || fail "Refusing to restore into /"
    if [ -d "$target" ] && ! dir_is_empty "$target"; then
        [ "$FORCE_RESTORE" = true ] || fail "Target directory is not empty: $target. Re-run with --force to overwrite it."
        local backup_dir
        backup_dir="${target}.pre-restore-$(date +%Y%m%d%H%M%S)"
        warn "Moving existing target contents to $backup_dir"
        mkdir -p "$backup_dir"
        shopt -s dotglob nullglob
        mv "$target"/* "$backup_dir"/
        shopt -u dotglob nullglob
    fi
    mkdir -p "$target"
}

restore_backup() {
    local archive="${1:-}"
    [ -n "$archive" ] || fail "Missing archive path"
    [ -f "$archive" ] || fail "Archive not found: $archive"

    need_cmd docker
    need_cmd tar
    detect_compose_cmd

    local staging target
    staging="$(mktemp -d)"

    tar xzf "$archive" -C "$staging"
    [ -f "$staging/manifest.env" ] || fail "Invalid archive: manifest.env missing"
    # shellcheck disable=SC1091
    source "$staging/manifest.env"

    target="${TARGET_DIR:-$(pwd -P)}"
    target="$(abs_path "$target")"
    log "Archive storage mode: $STORAGE_MODE"
    log "Restore target: $target"
    confirm "Restore this archive to $target?"

    prepare_target_dir "$target"
    tar xzf "$staging/deployment.tar.gz" -C "$target"

    cd "$target"
    COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
    [ -f "$COMPOSE_FILE" ] || fail "Restored compose file not found: $COMPOSE_FILE"

    if [ "$STORAGE_MODE" = "named" ]; then
        restore_volume "$SUB2API_VOLUME" "$staging/volumes/sub2api_data.tar.gz"
        restore_volume "$POSTGRES_VOLUME" "$staging/volumes/postgres_data.tar.gz"
        restore_volume "$REDIS_VOLUME" "$staging/volumes/redis_data.tar.gz"
    fi

    if [ "$START_AFTER_RESTORE" = true ]; then
        log "Starting restored stack"
        compose_with_project "${PROJECT_NAME:-}" up -d
        compose_with_project "${PROJECT_NAME:-}" ps
    else
        ok "Restore completed. Start it with: cd $target && docker compose -f $COMPOSE_FILE up -d"
    fi
    rm -rf "$staging"
}

parse_remote_target() {
    local spec="$1"
    [[ "$spec" == *:* ]] || fail "Remote target must look like user@host:/target/dir"
    REMOTE_HOST="${spec%%:*}"
    REMOTE_DIR="${spec#*:}"
    [ -n "$REMOTE_HOST" ] || fail "Remote host is empty"
    [ -n "$REMOTE_DIR" ] || fail "Remote target directory is empty"
    [[ "$REMOTE_DIR" = /* ]] || fail "Remote target directory must be absolute"
}

remote_ssh() {
    if [ -n "$SSH_PORT" ]; then
        ssh -p "$SSH_PORT" "$REMOTE_HOST" "$@"
    else
        ssh "$REMOTE_HOST" "$@"
    fi
}

remote_scp() {
    if [ -n "$SSH_PORT" ]; then
        scp -P "$SSH_PORT" "$1" "$2"
    else
        scp "$1" "$2"
    fi
}

migrate_remote() {
    local remote_spec="${1:-}"
    [ -n "$remote_spec" ] || fail "Missing remote target"
    need_cmd ssh
    need_cmd scp
    parse_remote_target "$remote_spec"

    create_backup

    local archive base remote_archive restore_args remote_cmd
    archive="$BACKUP_RESULT"
    base="$(basename "$archive")"
    remote_archive="/tmp/$base"

    log "Uploading archive to $REMOTE_HOST:$remote_archive"
    remote_scp "$archive" "$REMOTE_HOST:$remote_archive"

    restore_args=(restore "$remote_archive" --target-dir "$REMOTE_DIR" --start --yes)
    if [ "$FORCE_RESTORE" = true ]; then
        restore_args+=(--force)
    fi

    log "Restoring on remote server: $REMOTE_HOST"
    remote_cmd="bash -s --"
    for arg in "${restore_args[@]}"; do
        remote_cmd+=" $(safe_quote "$arg")"
    done
    remote_ssh "$remote_cmd" < "$SCRIPT_PATH"

    if [ "$REMOTE_KEEP_ARCHIVE" = false ]; then
        remote_ssh "rm -f $(safe_quote "$remote_archive")"
    fi

    ok "Migration completed. Source stack was left stopped intentionally."
}

parse_args() {
    [ "$#" -gt 0 ] || { usage; exit 1; }
    ACTION="$1"
    shift

    POSITIONAL=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--compose-file) [ -n "${2:-}" ] || fail "$1 requires a value"; COMPOSE_FILE="$2"; shift 2 ;;
            -o|--output) [ -n "${2:-}" ] || fail "$1 requires a value"; OUTPUT_FILE="$2"; shift 2 ;;
            -t|--target-dir) [ -n "${2:-}" ] || fail "$1 requires a value"; TARGET_DIR="$2"; shift 2 ;;
            -p|--ssh-port) [ -n "${2:-}" ] || fail "$1 requires a value"; SSH_PORT="$2"; shift 2 ;;
            -y|--yes) YES=true; shift ;;
            --no-stop) NO_STOP=true; shift ;;
            --start) START_AFTER_RESTORE=true; shift ;;
            --force) FORCE_RESTORE=true; shift ;;
            --keep-remote-archive) REMOTE_KEEP_ARCHIVE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) fail "Unknown option: $1" ;;
            *) POSITIONAL+=("$1"); shift ;;
        esac
    done
}

main() {
    parse_args "$@"
    case "$ACTION" in
        backup)
            [ "${#POSITIONAL[@]}" -eq 0 ] || fail "backup does not accept positional arguments"
            create_backup
            ;;
        restore)
            restore_backup "${POSITIONAL[0]:-}"
            ;;
        migrate)
            migrate_remote "${POSITIONAL[0]:-}"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            fail "Unknown action: $ACTION"
            ;;
    esac
}

main "$@"
