#!/usr/bin/env bash
set -euo pipefail

# Bulk multi-instance Docker management for Moltbot (1000+ instances)
# Usage:
#   ./docker-multi-bulk.sh generate [--config FILE]   Generate instance configs from YAML
#   ./docker-multi-bulk.sh up [--parallel N]          Start all instances
#   ./docker-multi-bulk.sh down [--parallel N]        Stop all instances
#   ./docker-multi-bulk.sh status                     Show all instance status
#   ./docker-multi-bulk.sh export                     Export docker-compose.generated.yml

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="$ROOT_DIR/.instances"
CONFIG_FILE="${MOLTBOT_INSTANCES_CONFIG:-$ROOT_DIR/instances.yaml}"
GENERATED_COMPOSE="$ROOT_DIR/docker-compose.generated.yml"
IMAGE_NAME="${CLAWDBOT_IMAGE:-moltbot:local}"
PARALLEL_LIMIT=10

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

check_deps() {
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose not available" >&2
    exit 1
  fi
}

usage() {
  cat <<EOF
Bulk multi-instance Docker management for Moltbot

Usage:
  $0 generate [options]     Generate instance configs from YAML
  $0 up [options]           Start all/specified instances
  $0 down [options]         Stop all/specified instances
  $0 status [options]       Show instance status
  $0 export                 Generate docker-compose.generated.yml
  $0 create-range <prefix> <start> <end> [options]
                            Quick bulk create without YAML

Options:
  --config FILE            Config file (default: instances.yaml)
  --parallel N             Parallel operations (default: 10)
  --filter PATTERN         Filter instances by name pattern
  --dry-run                Show what would be done

Examples:
  # From YAML config
  $0 generate --config instances.yaml
  $0 up --parallel 20
  $0 status --filter "user-*"

  # Quick bulk create (no YAML needed)
  $0 create-range user 1 1000 --gateway-start 19000

  # Export for external orchestration
  $0 export > docker-compose.1000-instances.yml
EOF
  exit 1
}

# Parse YAML using simple bash (no yq dependency for portability)
# For complex configs, recommend using the Python helper
parse_simple_yaml() {
  local file="$1"
  python3 - "$file" <<'PYTHON'
import sys
import yaml
import json

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
PYTHON
}

# Generate instance configs from YAML
cmd_generate() {
  local config_file="$CONFIG_FILE"
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config_file="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  if [[ ! -f "$config_file" ]]; then
    echo "Config file not found: $config_file" >&2
    echo "Copy instances.example.yaml to instances.yaml and customize" >&2
    exit 1
  fi

  require_cmd python3

  echo "==> Parsing config: $config_file"

  python3 - "$config_file" "$INSTANCES_DIR" "$dry_run" "$IMAGE_NAME" <<'PYTHON'
import sys
import yaml
import json
import os
import secrets
from pathlib import Path

config_file = sys.argv[1]
instances_dir = Path(sys.argv[2])
dry_run = sys.argv[3] == "true"
image_name = sys.argv[4]

with open(config_file) as f:
    config = yaml.safe_load(f)

defaults = config.get("defaults", {})
instances_config = config.get("instances", [])

# Extract defaults
config_base = defaults.get("config_base", os.path.expanduser("~/.clawdbot"))
workspace_base = defaults.get("workspace_base", os.path.expanduser("~/clawd"))
gateway_start = defaults.get("ports", {}).get("gateway_start", 18789)
bridge_start = defaults.get("ports", {}).get("bridge_start", 28789)
default_resources = defaults.get("resources", {})
docker_settings = defaults.get("docker", {})

def generate_token():
    return secrets.token_hex(32)

def expand_instances(instances_config):
    """Expand patterns and ranges into individual instance definitions"""
    expanded = []

    for item in instances_config:
        if "name" in item:
            # Single instance
            expanded.append(item)
        elif "pattern" in item and "range" in item:
            # Range pattern: user-{n:03d} with range [1, 100]
            pattern = item["pattern"]
            start, end = item["range"]
            gw_start = item.get("gateway_port_start", gateway_start)
            br_start = item.get("bridge_port_start", bridge_start)
            resources = item.get("resources", {})

            for i, n in enumerate(range(start, end + 1)):
                name = pattern.format(n=n)
                expanded.append({
                    "name": name,
                    "gateway_port": gw_start + i,
                    "bridge_port": br_start + i,
                    "resources": resources
                })
        elif "names" in item:
            # List of names
            names = item["names"]
            gw_start = item.get("gateway_port_start", gateway_start)
            br_start = item.get("bridge_port_start", bridge_start)
            resources = item.get("resources", {})

            for i, name in enumerate(names):
                expanded.append({
                    "name": name,
                    "gateway_port": gw_start + i,
                    "bridge_port": br_start + i,
                    "resources": resources
                })

    return expanded

instances = expand_instances(instances_config)
print(f"Generating {len(instances)} instance configurations...")

if not dry_run:
    instances_dir.mkdir(parents=True, exist_ok=True)

for inst in instances:
    name = inst["name"]
    gw_port = inst.get("gateway_port", gateway_start)
    br_port = inst.get("bridge_port", bridge_start)
    resources = {**default_resources, **inst.get("resources", {})}

    config_dir = f"{config_base}/{name}"
    workspace_dir = f"{workspace_base}/{name}"

    env_content = f"""# Instance: {name}
# Auto-generated from {config_file}
INSTANCE={name}
CLAWDBOT_GATEWAY_PORT={gw_port}
CLAWDBOT_BRIDGE_PORT={br_port}
CLAWDBOT_INTERNAL_GATEWAY_PORT=18789
CLAWDBOT_INTERNAL_BRIDGE_PORT=18790
CLAWDBOT_CONFIG_DIR={config_dir}
CLAWDBOT_WORKSPACE_DIR={workspace_dir}
CLAWDBOT_GATEWAY_TOKEN={generate_token()}
CLAWDBOT_GATEWAY_BIND=lan
CLAWDBOT_IMAGE={image_name}
CLAWDBOT_MEMORY={resources.get('memory', '512m')}
CLAWDBOT_MEMORY_SWAP={resources.get('memory_swap', '1g')}
CLAWDBOT_CPUS={resources.get('cpus', '0.5')}
CLAWDBOT_PIDS_LIMIT={resources.get('pids_limit', '100')}
"""

    if dry_run:
        print(f"  [dry-run] Would create: {name} (gateway:{gw_port}, bridge:{br_port})")
    else:
        env_file = instances_dir / f"{name}.env"
        env_file.write_text(env_content)

        # Create directories
        Path(config_dir).mkdir(parents=True, exist_ok=True)
        Path(workspace_dir).mkdir(parents=True, exist_ok=True)

        print(f"  Created: {name} (gateway:{gw_port}, bridge:{br_port})")

print(f"\nGenerated {len(instances)} instances")
if not dry_run:
    print(f"Instance configs stored in: {instances_dir}")
PYTHON
}

# Quick bulk create without YAML
cmd_create_range() {
  local prefix=""
  local start=""
  local end=""
  local gateway_start=19000
  local bridge_start=29000
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gateway-start) gateway_start="$2"; shift 2 ;;
      --bridge-start) bridge_start="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      -*)
        echo "Unknown option: $1" >&2
        usage
        ;;
      *)
        if [[ -z "$prefix" ]]; then
          prefix="$1"
        elif [[ -z "$start" ]]; then
          start="$1"
        elif [[ -z "$end" ]]; then
          end="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$prefix" || -z "$start" || -z "$end" ]]; then
    echo "Usage: $0 create-range <prefix> <start> <end> [--gateway-start PORT]" >&2
    exit 1
  fi

  local count=$((end - start + 1))
  echo "==> Creating $count instances: ${prefix}-${start} to ${prefix}-${end}"
  echo "    Gateway ports: $gateway_start - $((gateway_start + count - 1))"
  echo "    Bridge ports:  $bridge_start - $((bridge_start + count - 1))"

  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] Would create $count instances"
    exit 0
  fi

  mkdir -p "$INSTANCES_DIR"

  local i=0
  for n in $(seq "$start" "$end"); do
    local name="${prefix}-${n}"
    local gw_port=$((gateway_start + i))
    local br_port=$((bridge_start + i))
    local config_dir="$HOME/.clawdbot-${name}"
    local workspace_dir="$HOME/clawd-${name}"
    local token
    token=$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')

    cat > "$INSTANCES_DIR/${name}.env" <<EOF
INSTANCE=$name
CLAWDBOT_GATEWAY_PORT=$gw_port
CLAWDBOT_BRIDGE_PORT=$br_port
CLAWDBOT_INTERNAL_GATEWAY_PORT=18789
CLAWDBOT_INTERNAL_BRIDGE_PORT=18790
CLAWDBOT_CONFIG_DIR=$config_dir
CLAWDBOT_WORKSPACE_DIR=$workspace_dir
CLAWDBOT_GATEWAY_TOKEN=$token
CLAWDBOT_GATEWAY_BIND=lan
CLAWDBOT_IMAGE=$IMAGE_NAME
CLAWDBOT_MEMORY=512m
CLAWDBOT_MEMORY_SWAP=1g
CLAWDBOT_CPUS=0.5
CLAWDBOT_PIDS_LIMIT=100
EOF

    mkdir -p "$config_dir" "$workspace_dir"

    ((i++))
    if ((i % 100 == 0)); then
      echo "  Created $i / $count instances..."
    fi
  done

  echo "==> Created $count instances"
  echo "    Configs stored in: $INSTANCES_DIR"
}

# Start instances in parallel
cmd_up() {
  check_deps
  local parallel=$PARALLEL_LIMIT
  local filter=""
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel="$2"; shift 2 ;;
      --filter) filter="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  local env_files=()
  for f in "$INSTANCES_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    if [[ -n "$filter" ]]; then
      local name
      name=$(basename "$f" .env)
      [[ "$name" == $filter ]] || continue
    fi
    env_files+=("$f")
  done

  local total=${#env_files[@]}
  if [[ $total -eq 0 ]]; then
    echo "No instances found. Run 'generate' or 'create-range' first." >&2
    exit 1
  fi

  echo "==> Starting $total instances (parallel: $parallel)"

  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] Would start $total instances"
    exit 0
  fi

  # Create shared network if needed
  docker network create moltbot-network 2>/dev/null || true

  local started=0
  local pids=()

  for env_file in "${env_files[@]}"; do
    # shellcheck disable=SC1090
    (
      source "$env_file"
      docker compose -f "$ROOT_DIR/docker-compose.multi.yml" \
        --project-name "moltbot-${INSTANCE}" \
        up -d moltbot-gateway 2>&1 | sed "s/^/[$INSTANCE] /"
    ) &
    pids+=($!)

    # Limit parallelism
    if [[ ${#pids[@]} -ge $parallel ]]; then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi

    ((started++))
    if ((started % 50 == 0)); then
      echo "  Started $started / $total instances..."
    fi
  done

  # Wait for remaining
  wait "${pids[@]}" 2>/dev/null || true

  echo "==> Started $total instances"
}

# Stop instances in parallel
cmd_down() {
  check_deps
  local parallel=$PARALLEL_LIMIT
  local filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel="$2"; shift 2 ;;
      --filter) filter="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  local env_files=()
  for f in "$INSTANCES_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    if [[ -n "$filter" ]]; then
      local name
      name=$(basename "$f" .env)
      [[ "$name" == $filter ]] || continue
    fi
    env_files+=("$f")
  done

  local total=${#env_files[@]}
  echo "==> Stopping $total instances (parallel: $parallel)"

  local stopped=0
  local pids=()

  for env_file in "${env_files[@]}"; do
    (
      # shellcheck disable=SC1090
      source "$env_file"
      docker compose -f "$ROOT_DIR/docker-compose.multi.yml" \
        --project-name "moltbot-${INSTANCE}" \
        down 2>&1 | sed "s/^/[$INSTANCE] /"
    ) &
    pids+=($!)

    if [[ ${#pids[@]} -ge $parallel ]]; then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi

    ((stopped++))
  done

  wait "${pids[@]}" 2>/dev/null || true
  echo "==> Stopped $total instances"
}

# Show status
cmd_status() {
  local filter=""
  local format="table"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter) filter="$2"; shift 2 ;;
      --json) format="json"; shift ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  local running=0
  local stopped=0
  local total=0

  if [[ "$format" == "table" ]]; then
    printf "%-20s %-8s %-8s %-10s %-6s %s\n" "INSTANCE" "GATEWAY" "BRIDGE" "STATUS" "MEM" "CONFIG"
    printf "%-20s %-8s %-8s %-10s %-6s %s\n" "--------" "-------" "------" "------" "---" "------"
  fi

  local json_output="["

  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue

    local instance gw_port br_port config_dir memory status
    instance=$(grep "^INSTANCE=" "$env_file" | cut -d= -f2)
    gw_port=$(grep "^CLAWDBOT_GATEWAY_PORT=" "$env_file" | cut -d= -f2)
    br_port=$(grep "^CLAWDBOT_BRIDGE_PORT=" "$env_file" | cut -d= -f2)
    config_dir=$(grep "^CLAWDBOT_CONFIG_DIR=" "$env_file" | cut -d= -f2)
    memory=$(grep "^CLAWDBOT_MEMORY=" "$env_file" | cut -d= -f2)

    if [[ -n "$filter" && "$instance" != $filter ]]; then
      continue
    fi

    ((total++))

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^moltbot-gateway-${instance}$"; then
      status="running"
      ((running++))
    else
      status="stopped"
      ((stopped++))
    fi

    if [[ "$format" == "table" ]]; then
      printf "%-20s %-8s %-8s %-10s %-6s %s\n" "$instance" "$gw_port" "$br_port" "$status" "$memory" "$config_dir"
    else
      [[ "$json_output" != "[" ]] && json_output+=","
      json_output+="{\"name\":\"$instance\",\"gateway_port\":$gw_port,\"bridge_port\":$br_port,\"status\":\"$status\",\"memory\":\"$memory\"}"
    fi
  done

  if [[ "$format" == "json" ]]; then
    echo "${json_output}]"
  else
    echo ""
    echo "Total: $total | Running: $running | Stopped: $stopped"
  fi
}

# Export single docker-compose file for all instances
cmd_export() {
  echo "# Auto-generated Docker Compose for all Moltbot instances"
  echo "# Generated: $(date -Iseconds)"
  echo ""
  echo "services:"

  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue

    local instance gw_port br_port config_dir workspace_dir token memory cpus pids_limit
    instance=$(grep "^INSTANCE=" "$env_file" | cut -d= -f2)
    gw_port=$(grep "^CLAWDBOT_GATEWAY_PORT=" "$env_file" | cut -d= -f2)
    br_port=$(grep "^CLAWDBOT_BRIDGE_PORT=" "$env_file" | cut -d= -f2)
    config_dir=$(grep "^CLAWDBOT_CONFIG_DIR=" "$env_file" | cut -d= -f2)
    workspace_dir=$(grep "^CLAWDBOT_WORKSPACE_DIR=" "$env_file" | cut -d= -f2)
    token=$(grep "^CLAWDBOT_GATEWAY_TOKEN=" "$env_file" | cut -d= -f2)
    memory=$(grep "^CLAWDBOT_MEMORY=" "$env_file" | cut -d= -f2)
    cpus=$(grep "^CLAWDBOT_CPUS=" "$env_file" | cut -d= -f2)
    pids_limit=$(grep "^CLAWDBOT_PIDS_LIMIT=" "$env_file" | cut -d= -f2)

    cat <<EOF
  moltbot-${instance}:
    container_name: moltbot-gateway-${instance}
    image: ${IMAGE_NAME}
    environment:
      HOME: /home/node
      CLAWDBOT_GATEWAY_TOKEN: ${token}
      CLAWDBOT_INSTANCE: ${instance}
    volumes:
      - ${config_dir}:/home/node/.clawdbot
      - ${workspace_dir}:/home/node/clawd
    ports:
      - "${gw_port}:18789"
      - "${br_port}:18790"
    deploy:
      resources:
        limits:
          memory: ${memory:-512m}
          cpus: "${cpus:-0.5}"
          pids: ${pids_limit:-100}
    init: true
    restart: unless-stopped
    command: ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]

EOF
  done

  echo "networks:"
  echo "  default:"
  echo "    name: moltbot-network"
}

# Main
[[ $# -eq 0 ]] && usage

cmd="$1"
shift

case "$cmd" in
  generate) cmd_generate "$@" ;;
  create-range) cmd_create_range "$@" ;;
  up|start) cmd_up "$@" ;;
  down|stop) cmd_down "$@" ;;
  status|list|ls) cmd_status "$@" ;;
  export) cmd_export "$@" ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $cmd" >&2; usage ;;
esac
