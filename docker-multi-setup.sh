#!/usr/bin/env bash
set -euo pipefail

# Multi-instance Docker management for Moltbot
# Usage:
#   ./docker-multi-setup.sh create <instance-name> [--gateway-port PORT] [--bridge-port PORT]
#   ./docker-multi-setup.sh start <instance-name>
#   ./docker-multi-setup.sh stop <instance-name>
#   ./docker-multi-setup.sh remove <instance-name>
#   ./docker-multi-setup.sh list
#   ./docker-multi-setup.sh status [instance-name]
#   ./docker-multi-setup.sh logs <instance-name> [-f]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.multi.yml"
INSTANCES_DIR="$ROOT_DIR/.instances"
IMAGE_NAME="${CLAWDBOT_IMAGE:-moltbot:local}"

# Default port ranges
DEFAULT_BASE_GATEWAY_PORT=18789
DEFAULT_BASE_BRIDGE_PORT=18790

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose not available (try: docker compose version)" >&2
  exit 1
fi

mkdir -p "$INSTANCES_DIR"

usage() {
  cat <<EOF
Multi-instance Docker management for Moltbot

Usage:
  $0 create <instance-name> [options]    Create and start a new instance
  $0 start <instance-name>               Start an existing instance
  $0 stop <instance-name>                Stop a running instance
  $0 remove <instance-name>              Remove an instance (stops if running)
  $0 list                                List all instances with their ports
  $0 status [instance-name]              Show status of instance(s)
  $0 logs <instance-name> [-f]           View instance logs
  $0 cli <instance-name> [args...]       Run CLI command in instance
  $0 onboard <instance-name>             Run onboarding for instance
  $0 ports                               Show next available ports

Options for 'create':
  --gateway-port PORT    Gateway port (default: auto-assigned)
  --bridge-port PORT     Bridge port (default: auto-assigned)
  --config-dir DIR       Config directory (default: ~/.moltbot-<instance>)
  --workspace-dir DIR    Workspace directory (default: ~/clawd-<instance>)
  --no-onboard           Skip interactive onboarding

Examples:
  $0 create bot1                         # Auto-assign ports
  $0 create bot2 --gateway-port 18791    # Specify gateway port
  $0 create bot3 --gateway-port 18793 --bridge-port 18794
  $0 list                                # Show all instances
  $0 cli bot1 channels status            # Run CLI command
EOF
  exit 1
}

get_instance_env_file() {
  local instance="$1"
  echo "$INSTANCES_DIR/${instance}.env"
}

instance_exists() {
  local instance="$1"
  [[ -f "$(get_instance_env_file "$instance")" ]]
}

load_instance_env() {
  local instance="$1"
  local env_file
  env_file="$(get_instance_env_file "$instance")"
  if [[ ! -f "$env_file" ]]; then
    echo "Instance '$instance' not found" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  # Use set -a to auto-export variables so Docker Compose can read them
  set -a
  source "$env_file"
  set +a
}

get_used_ports() {
  local port_type="$1"  # GATEWAY or BRIDGE
  local ports=()
  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue
    local port
    port=$(grep "^CLAWDBOT_${port_type}_PORT=" "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$port" ]] && ports+=("$port")
  done
  printf '%s\n' "${ports[@]}" | sort -n
}

get_all_used_ports() {
  local ports=()
  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue
    local gw_port br_port
    gw_port=$(grep "^CLAWDBOT_GATEWAY_PORT=" "$env_file" 2>/dev/null | cut -d= -f2)
    br_port=$(grep "^CLAWDBOT_BRIDGE_PORT=" "$env_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$gw_port" ]] && ports+=("$gw_port")
    [[ -n "$br_port" ]] && ports+=("$br_port")
  done
  printf '%s\n' "${ports[@]}" | sort -n
}

is_port_available() {
  local port="$1"
  local all_used="$2"

  # Check if port is in our instances
  if echo "$all_used" | grep -q "^${port}$"; then
    return 1
  fi

  # Check if port is in use on the system
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    return 1
  fi

  # Check if port is used by Docker
  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
    return 1
  fi

  return 0
}

find_next_available_port_pair() {
  local base_port="$1"
  local all_used
  all_used=$(get_all_used_ports)

  local port=$base_port
  while true; do
    local next_port=$((port + 1))
    # Find a pair where both ports are available
    if is_port_available "$port" "$all_used" && is_port_available "$next_port" "$all_used"; then
      echo "$port"
      return
    fi
    ((port++))
  done
}

find_next_available_port() {
  local base_port="$1"
  local port_type="$2"
  local used_ports
  used_ports=$(get_used_ports "$port_type")

  local port=$base_port
  while true; do
    if ! echo "$used_ports" | grep -q "^${port}$"; then
      # Also check if port is in use on the system
      if ! ss -ltn 2>/dev/null | grep -q ":${port} " && \
         ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
        echo "$port"
        return
      fi
    fi
    ((port++))
  done
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 -c 'import secrets; print(secrets.token_hex(32))'
  fi
}

cmd_create() {
  local instance=""
  local gateway_port=""
  local bridge_port=""
  local config_dir=""
  local workspace_dir=""
  local skip_onboard=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gateway-port)
        gateway_port="$2"
        shift 2
        ;;
      --bridge-port)
        bridge_port="$2"
        shift 2
        ;;
      --config-dir)
        config_dir="$2"
        shift 2
        ;;
      --workspace-dir)
        workspace_dir="$2"
        shift 2
        ;;
      --no-onboard)
        skip_onboard=true
        shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage
        ;;
      *)
        if [[ -z "$instance" ]]; then
          instance="$1"
        else
          echo "Unexpected argument: $1" >&2
          usage
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$instance" ]]; then
    echo "Instance name required" >&2
    usage
  fi

  # Validate instance name (alphanumeric, dash, underscore)
  if ! [[ "$instance" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid instance name. Use only alphanumeric characters, dashes, and underscores." >&2
    exit 1
  fi

  if instance_exists "$instance"; then
    echo "Instance '$instance' already exists" >&2
    exit 1
  fi

  # Auto-assign ports if not specified
  # When both ports need auto-assignment, find a consecutive pair to avoid conflicts
  if [[ -z "$gateway_port" ]] && [[ -z "$bridge_port" ]]; then
    gateway_port=$(find_next_available_port_pair "$DEFAULT_BASE_GATEWAY_PORT")
    bridge_port=$((gateway_port + 1))
  elif [[ -z "$gateway_port" ]]; then
    gateway_port=$(find_next_available_port "$DEFAULT_BASE_GATEWAY_PORT" "GATEWAY")
  elif [[ -z "$bridge_port" ]]; then
    bridge_port=$(find_next_available_port "$DEFAULT_BASE_BRIDGE_PORT" "BRIDGE")
  fi

  # Set default directories
  [[ -z "$config_dir" ]] && config_dir="$HOME/.moltbot-${instance}"
  [[ -z "$workspace_dir" ]] && workspace_dir="$HOME/clawd-${instance}"

  # Generate token
  local token
  token=$(generate_token)

  # Create directories
  mkdir -p "$config_dir"
  mkdir -p "$workspace_dir"

  # Save instance configuration
  local env_file
  env_file="$(get_instance_env_file "$instance")"
  cat > "$env_file" <<EOF
# Instance: $instance
# Created: $(date -Iseconds)
INSTANCE=$instance
CLAWDBOT_GATEWAY_PORT=$gateway_port
CLAWDBOT_BRIDGE_PORT=$bridge_port
CLAWDBOT_INTERNAL_GATEWAY_PORT=18789
CLAWDBOT_INTERNAL_BRIDGE_PORT=18790
CLAWDBOT_CONFIG_DIR=$config_dir
CLAWDBOT_WORKSPACE_DIR=$workspace_dir
CLAWDBOT_GATEWAY_TOKEN=$token
CLAWDBOT_GATEWAY_BIND=lan
CLAWDBOT_IMAGE=$IMAGE_NAME
EOF

  echo "==> Created instance '$instance'"
  echo "    Gateway port: $gateway_port"
  echo "    Bridge port:  $bridge_port"
  echo "    Config:       $config_dir"
  echo "    Workspace:    $workspace_dir"
  echo "    Token:        $token"
  echo ""

  # Build image if needed
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "==> Building Docker image: $IMAGE_NAME"
    docker build \
      --build-arg "CLAWDBOT_DOCKER_APT_PACKAGES=${CLAWDBOT_DOCKER_APT_PACKAGES:-}" \
      -t "$IMAGE_NAME" \
      -f "$ROOT_DIR/Dockerfile" \
      "$ROOT_DIR"
  fi

  # Run onboarding if not skipped
  if [[ "$skip_onboard" == false ]]; then
    echo ""
    echo "==> Onboarding (interactive)"
    echo "When prompted:"
    echo "  - Gateway bind: lan"
    echo "  - Gateway auth: token"
    echo "  - Gateway token: $token"
    echo "  - Tailscale exposure: Off"
    echo "  - Install Gateway daemon: No"
    echo ""
    # shellcheck disable=SC1090
    # Use set -a to auto-export variables so Docker Compose can read them
    set -a
    source "$env_file"
    set +a
    docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" run --rm moltbot-cli onboard --no-install-daemon
  fi

  # Start the instance
  cmd_start "$instance"

  echo ""
  echo "==> Instance '$instance' is running"
  echo "    URL: http://127.0.0.1:${gateway_port}/"
  echo ""
  echo "Commands:"
  echo "  $0 logs $instance -f"
  echo "  $0 cli $instance health --token \"$token\""
  echo "  $0 stop $instance"
}

cmd_start() {
  local instance="$1"
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  load_instance_env "$instance"

  echo "==> Starting instance '$instance'"
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" up -d moltbot-gateway
  echo "    Gateway: http://127.0.0.1:${CLAWDBOT_GATEWAY_PORT}/"
}

cmd_stop() {
  local instance="$1"
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  load_instance_env "$instance"

  echo "==> Stopping instance '$instance'"
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" down
}

cmd_remove() {
  local instance="$1"
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  if ! instance_exists "$instance"; then
    echo "Instance '$instance' not found" >&2
    exit 1
  fi

  load_instance_env "$instance"

  echo "==> Removing instance '$instance'"

  # Stop containers if running
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" down 2>/dev/null || true

  # Remove env file
  rm -f "$(get_instance_env_file "$instance")"

  echo "Instance '$instance' removed."
  echo "Note: Config ($CLAWDBOT_CONFIG_DIR) and workspace ($CLAWDBOT_WORKSPACE_DIR) directories were NOT deleted."
  echo "Delete them manually if no longer needed."
}

cmd_list() {
  echo "Moltbot Instances:"
  echo ""
  printf "%-15s %-12s %-12s %-10s %s\n" "INSTANCE" "GATEWAY" "BRIDGE" "STATUS" "CONFIG"
  printf "%-15s %-12s %-12s %-10s %s\n" "--------" "-------" "------" "------" "------"

  local found=false
  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue
    found=true

    local instance gateway_port bridge_port config_dir status
    instance=$(grep "^INSTANCE=" "$env_file" | cut -d= -f2)
    gateway_port=$(grep "^CLAWDBOT_GATEWAY_PORT=" "$env_file" | cut -d= -f2)
    bridge_port=$(grep "^CLAWDBOT_BRIDGE_PORT=" "$env_file" | cut -d= -f2)
    config_dir=$(grep "^CLAWDBOT_CONFIG_DIR=" "$env_file" | cut -d= -f2)

    # Check container status
    if docker ps --format '{{.Names}}' | grep -q "^moltbot-gateway-${instance}$"; then
      status="running"
    else
      status="stopped"
    fi

    printf "%-15s %-12s %-12s %-10s %s\n" "$instance" "$gateway_port" "$bridge_port" "$status" "$config_dir"
  done

  if [[ "$found" == false ]]; then
    echo "(no instances)"
  fi
}

cmd_status() {
  local instance="${1:-}"

  if [[ -n "$instance" ]]; then
    load_instance_env "$instance"
    echo "Instance: $instance"
    echo "  Gateway port:   $CLAWDBOT_GATEWAY_PORT"
    echo "  Bridge port:    $CLAWDBOT_BRIDGE_PORT"
    echo "  Config dir:     $CLAWDBOT_CONFIG_DIR"
    echo "  Workspace dir:  $CLAWDBOT_WORKSPACE_DIR"
    echo "  Token:          $CLAWDBOT_GATEWAY_TOKEN"

    if docker ps --format '{{.Names}}' | grep -q "^moltbot-gateway-${instance}$"; then
      echo "  Status:         running"
      echo "  URL:            http://127.0.0.1:${CLAWDBOT_GATEWAY_PORT}/"
    else
      echo "  Status:         stopped"
    fi
  else
    cmd_list
  fi
}

cmd_logs() {
  local instance="$1"
  shift || true
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  load_instance_env "$instance"
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" logs "$@" moltbot-gateway
}

cmd_cli() {
  local instance="$1"
  shift || true
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  load_instance_env "$instance"
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" run --rm moltbot-cli "$@"
}

cmd_onboard() {
  local instance="$1"
  [[ -z "$instance" ]] && { echo "Instance name required" >&2; usage; }

  load_instance_env "$instance"

  echo "==> Onboarding instance '$instance'"
  echo "When prompted:"
  echo "  - Gateway bind: lan"
  echo "  - Gateway auth: token"
  echo "  - Gateway token: $CLAWDBOT_GATEWAY_TOKEN"
  echo "  - Tailscale exposure: Off"
  echo "  - Install Gateway daemon: No"
  echo ""
  docker compose -f "$COMPOSE_FILE" --project-name "moltbot-${instance}" run --rm moltbot-cli onboard --no-install-daemon
}

cmd_ports() {
  local next_gateway next_bridge
  next_gateway=$(find_next_available_port_pair "$DEFAULT_BASE_GATEWAY_PORT")
  next_bridge=$((next_gateway + 1))

  echo "Next available ports:"
  echo "  Gateway: $next_gateway"
  echo "  Bridge:  $next_bridge"
  echo ""
  echo "Used ports:"
  printf "  %-10s %s\n" "GATEWAY" "BRIDGE"

  for env_file in "$INSTANCES_DIR"/*.env; do
    [[ -f "$env_file" ]] || continue
    local instance gateway_port bridge_port
    instance=$(grep "^INSTANCE=" "$env_file" | cut -d= -f2)
    gateway_port=$(grep "^CLAWDBOT_GATEWAY_PORT=" "$env_file" | cut -d= -f2)
    bridge_port=$(grep "^CLAWDBOT_BRIDGE_PORT=" "$env_file" | cut -d= -f2)
    printf "  %-10s %-10s (%s)\n" "$gateway_port" "$bridge_port" "$instance"
  done
}

# Main command dispatch
[[ $# -eq 0 ]] && usage

cmd="$1"
shift

case "$cmd" in
  create)
    cmd_create "$@"
    ;;
  start)
    cmd_start "${1:-}"
    ;;
  stop)
    cmd_stop "${1:-}"
    ;;
  remove|rm|delete)
    cmd_remove "${1:-}"
    ;;
  list|ls)
    cmd_list
    ;;
  status)
    cmd_status "${1:-}"
    ;;
  logs)
    cmd_logs "$@"
    ;;
  cli)
    cmd_cli "$@"
    ;;
  onboard)
    cmd_onboard "${1:-}"
    ;;
  ports)
    cmd_ports
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    ;;
esac
