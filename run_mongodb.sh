#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Error / warning
# -----------------------------
err() { echo "Error: $*" >&2; }
warn() { echo "Warning: $*" >&2; }

# -----------------------------
# Defaults
# -----------------------------
RUNTIME=""
MONGO_NAME="argot-mongodb"
MONGO_PORT="27017"
MONGO_DATA="${HOME}/mongo_data"
DUMP_FOLDER=""
SIF_IMAGE=""
DOCKER_IMAGE="mongo:8"
FORCE=0

WORKERS=""
PARALLEL_COLLECTIONS="3"

# -----------------------------
# Usage
# -----------------------------
usage() {
    echo "MongoDB Setup"
    echo
    echo "Start a MongoDB instance (Docker or Singularity) and optionally restore a dump directory."
    echo
    echo "Usage:"
    echo "  $0 [-r <runtime>] [-n <name>] [-p <port>] [-d <data_dir>] [-f <dump_dir>] [-i <sif>] [--force]"
    echo
    echo "Options:"
    echo "  -r <runtime>      Container runtime: docker | singularity (default: auto-detect)"
    echo "  -n <name>         Container/instance name (default: argot-mongodb)"
    echo "  -p <port>         MongoDB port (default: 27017)"
    echo "  -d <data_dir>     Host directory for persistent data (default: ~/mongo_data)"
    echo "  -f <dump_dir>     Path to dump directory (will be mounted as /dump)"
    echo "  -I <image>        MongoDB image name (default: mongo:8)"
    echo "  -i <sif>          Singularity SIF image (optional, default: docker://<image>)"
    echo "  --force           Remove existing data directory before starting"
    echo "  -w <workers>      Total insertion workers budget (split across collections)"
    echo "                    (default: max available, capped at 16 workers per collection)"
    echo "  -c <collections>  Number of parallel collections (default: 3)"
    echo "  -h                Show this help message and exit"
    echo
    exit 1
}

# -----------------------------
# Parse args
# -----------------------------
args=()
for arg in "$@"; do
    case $arg in
        --force) FORCE=1 ;;
        --) ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

while getopts ":r:n:p:d:f:I:i:w:c:h" opt; do
    case $opt in
        r) RUNTIME=$OPTARG ;;
        n) MONGO_NAME=$OPTARG ;;
        p) MONGO_PORT=$OPTARG ;;
        d) MONGO_DATA=$OPTARG ;;
        f) DUMP_FOLDER=$OPTARG ;;
        I) DOCKER_IMAGE=$OPTARG ;;
        i) SIF_IMAGE=$OPTARG ;;
        w) WORKERS=$OPTARG ;;
        c) PARALLEL_COLLECTIONS=$OPTARG ;;
        h) usage ;;
        \?) err "unknown argument '-$OPTARG'"; usage ;;
        :) err "missing required value for -$OPTARG"; usage ;;
    esac
done

# -----------------------------
# Validate arguments
# -----------------------------
[[ "$MONGO_PORT" =~ ^[0-9]+$ ]] || {
    err "invalid value for -p <port> (got '$MONGO_PORT')"
    exit 1
}

if [[ -n "$SIF_IMAGE" ]]; then
    if [[ "$SIF_IMAGE" != docker://* && ! -f "$SIF_IMAGE" ]]; then
        err "file not found '$SIF_IMAGE' (-i)"
        exit 1
    fi
fi

if [[ -n "$WORKERS" ]]; then
    [[ "$WORKERS" =~ ^[0-9]+$ && "$WORKERS" -ge 1 ]] || {
        err "invalid value for -w <workers> (must be >=1 integer, got '$WORKERS')"
        exit 1
    }
fi

[[ "$PARALLEL_COLLECTIONS" =~ ^[0-9]+$ && "$PARALLEL_COLLECTIONS" -ge 1 ]] || {
    err "invalid value for collections (must be >=1 integer, got '$PARALLEL_COLLECTIONS')"
    exit 1
}

echo "=== MongoDB setup ==="

# Resolve absolute path (realpath -m is GNU coreutils; fall back to Python on macOS)
if realpath -m / >/dev/null 2>&1; then
    MONGO_DATA="$(realpath -m "${MONGO_DATA}")"
else
    MONGO_DATA="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${MONGO_DATA}")"
fi

if [[ -n "${DUMP_FOLDER}" ]]; then
    if realpath -m / >/dev/null 2>&1; then
        DUMP_FOLDER="$(realpath -m "${DUMP_FOLDER}")"
    else
        DUMP_FOLDER="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${DUMP_FOLDER}")"
    fi
fi

# Safety checks
if [[ -z "${MONGO_DATA}" || "${MONGO_DATA}" == "/" ]]; then
    err "refusing to use unsafe path '${MONGO_DATA}'"
    exit 1
fi

# Disallow critical system paths
case "${MONGO_DATA}" in
    /bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
        err "refusing to use system path '${MONGO_DATA}'"
        exit 1
        ;;
esac

# Handle existing data directory
if [[ -d "${MONGO_DATA}" ]]; then
    if [[ "${FORCE}" -eq 1 ]]; then
        warn "removing existing data directory '${MONGO_DATA}'"
        rm -rf "${MONGO_DATA}"
    else
        warn "using existing data directory '${MONGO_DATA}' (use --force to remove it)"
    fi
fi
mkdir -p "${MONGO_DATA}"

# -----------------------------
# Auto-detect workers
# -----------------------------
detect_workers() {
    local nproc=1

    if command -v nproc >/dev/null 2>&1; then
        nproc=$(nproc)
    elif command -v sysctl >/dev/null 2>&1; then
        nproc=$(sysctl -n hw.ncpu)
    fi

    # leave 2 CPUs free (minimum 1)
    local safe=$((nproc - 2))
    [[ $safe -lt 1 ]] && safe=1

    # total workers (global budget)
    if [[ -z "$WORKERS" ]]; then
        WORKERS=$safe
    fi

    local TOTAL_WORKERS="$WORKERS"

    # cap collections to total workers
    if [[ "$PARALLEL_COLLECTIONS" -gt "$TOTAL_WORKERS" ]]; then
        PARALLEL_COLLECTIONS="$TOTAL_WORKERS"
    fi

    # -----------------------------
    # Split workers across collections
    # -----------------------------
    WORKERS=$(( (TOTAL_WORKERS + PARALLEL_COLLECTIONS - 1) / PARALLEL_COLLECTIONS ))
    [[ "$WORKERS" -lt 1 ]] && WORKERS=1
    # Cap at 16
    [[ "$WORKERS" -gt 16 ]] && WORKERS=16

    echo "Total workers:        ${TOTAL_WORKERS}"
    echo "Parallel collections: ${PARALLEL_COLLECTIONS}"
    echo "Workers/collection:   ${WORKERS}"
}

# -----------------------------
# Auto-detect runtime
# -----------------------------
if [[ -z "$RUNTIME" ]]; then
    if command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v singularity >/dev/null 2>&1; then
        RUNTIME="singularity"
    else
        err "no supported container runtime found (docker or singularity)"
        exit 1
    fi
    echo "Auto-detected runtime: $RUNTIME"
fi

case "$RUNTIME" in
    docker|singularity) ;;
    *) err "invalid value for -r <runtime> (got '$RUNTIME')"; exit 1 ;;
esac

# -----------------------------
# Docker implementation
# -----------------------------
run_docker() {
    command -v docker >/dev/null 2>&1 || {
        err "required executable not found 'docker'"
        exit 1
    }

    if docker ps -a --format '{{.Names}}' | grep -q "^${MONGO_NAME}$"; then
        echo "Container '${MONGO_NAME}' already exists"
        warn "reusing existing container '${MONGO_NAME}' (configuration may differ)"

        if docker ps --format '{{.Names}}' | grep -q "^${MONGO_NAME}$"; then
            echo "MongoDB already running"
        else
            echo "Starting container..."
            docker start "${MONGO_NAME}"
        fi
    else
        echo "Creating MongoDB container..."

        local dump_mount=()
        if [[ -n "${DUMP_FOLDER}" ]]; then
            dump_mount=(-v "${DUMP_FOLDER}:/dump")
        fi

        docker run -d \
            --init \
            --name "${MONGO_NAME}" \
            -p "${MONGO_PORT}:27017" \
            -v "${MONGO_DATA}:/data/db" \
            "${dump_mount[@]+"${dump_mount[@]}"}" \
            "${DOCKER_IMAGE}" || {
                err "failed to start container (port ${MONGO_PORT} in use?)"
                exit 1
            }
    fi
}

# -----------------------------
# Singularity implementation
# -----------------------------
run_singularity() {
    command -v singularity >/dev/null 2>&1 || {
        err "required executable not found 'singularity'"
        exit 1
    }

    local image="${SIF_IMAGE:-docker://${DOCKER_IMAGE}}"

    if singularity instance list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${MONGO_NAME}$"; then
        echo "Instance '${MONGO_NAME}' already running"
        warn "reusing existing instance '${MONGO_NAME}' (configuration may differ)"
    else
        echo "Starting Singularity instance..."

        local dump_bind=()
        if [[ -n "${DUMP_FOLDER}" ]]; then
            dump_bind=(--bind "${DUMP_FOLDER}:/dump")
        fi

        singularity instance start \
            --bind "${MONGO_DATA}:/data/db" \
            "${dump_bind[@]+"${dump_bind[@]}"}" \
            "${image}" \
            "${MONGO_NAME}" || {
                err "failed to start container"
                exit 1
            }

        echo "Launching mongod..."

        local mongod_log="${MONGO_DATA}/mongod.log.$(date +%s)"

        nohup singularity exec instance://"${MONGO_NAME}" \
            /bin/bash -c "mongod --dbpath /data/db --bind_ip 0.0.0.0 --port ${MONGO_PORT}" \
            > "${mongod_log}" 2>&1 &

        echo "mongod launched (log: ${mongod_log})"
    fi
}

# -----------------------------
# Wait for MongoDB
# -----------------------------
wait_mongo() {
    echo "Waiting for MongoDB..."

    ready=0
    for i in $(seq 1 30); do
        if [[ "$RUNTIME" == "docker" ]]; then
            if docker exec "${MONGO_NAME}" \
                     mongosh --quiet --eval "db.runCommand({ ping: 1 })" >/dev/null 2>&1; then
                ready=1
                break
            fi
        else
            if singularity exec instance://"${MONGO_NAME}" \
                     mongosh --port "${MONGO_PORT}" --quiet --eval "db.runCommand({ ping: 1 })" >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 1
    done

    [[ "$ready" -eq 1 ]] || {
        err "MongoDB did not become ready in time"
        exit 1
    }

    echo "MongoDB is ready (localhost:${MONGO_PORT})"
}

# -----------------------------
# Restore dump
# -----------------------------
restore_dump() {
    if [[ -z "${DUMP_FOLDER}" ]]; then
        echo "No dump provided, skipping restore"
        return
    fi

    detect_workers

    # Validate on host BEFORE trying container restore
    if [[ ! -d "${DUMP_FOLDER}" ]]; then
        err "dump folder not found '${DUMP_FOLDER}'"
        exit 1
    fi

    echo "Restoring database from dump (mounted at /dump)..."
    warn "existing data will be overwritten (--drop)"

    if [[ "${RUNTIME}" == "docker" ]]; then
        docker exec "${MONGO_NAME}" \
            mongorestore \
            --drop \
            --numInsertionWorkersPerCollection "${WORKERS}" \
            --numParallelCollections "${PARALLEL_COLLECTIONS}" \
            /dump || {
                err "mongorestore failed (docker)"
                exit 1
            }
    else
        singularity exec instance://"${MONGO_NAME}" \
            mongorestore \
            --port "${MONGO_PORT}" \
            --drop \
            --numInsertionWorkersPerCollection "${WORKERS}" \
            --numParallelCollections "${PARALLEL_COLLECTIONS}" \
            /dump || {
                err "mongorestore failed (singularity)"
                exit 1
            }
    fi

    echo "Restore complete"
}

# -----------------------------
# Main
# -----------------------------
case "$RUNTIME" in
    docker) run_docker ;;
    singularity) run_singularity ;;
esac

wait_mongo
restore_dump

# -----------------------------
# Final info
# -----------------------------
echo
echo "MongoDB is running:"
echo "  Runtime:  ${RUNTIME}"
echo "  Host:     localhost"
echo "  Port:     ${MONGO_PORT}"
echo "  Name:     ${MONGO_NAME}"
echo "  Data dir: ${MONGO_DATA}"

echo
echo "=== DONE ==="