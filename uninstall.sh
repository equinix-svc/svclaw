#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw uninstaller.
# Removes the host-side resources created by the installer/setup flow:
#   - NemoClaw helper services
#   - All OpenShell sandboxes plus the NemoClaw gateway/providers
#   - ~/.nemoclaw plus ~/.config/{openshell,nemoclaw} state
#   - Global nemoclaw npm install/link
#   - OpenShell binary if it was installed to the standard installer path

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[uninstall]${NC} $1"; }
warn() { echo -e "${YELLOW}[uninstall]${NC} $1"; }
fail() { echo -e "${RED}[uninstall]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NEMOCLAW_STATE_DIR="${HOME}/.nemoclaw"
OPENSHELL_CONFIG_DIR="${HOME}/.config/openshell"
NEMOCLAW_CONFIG_DIR="${HOME}/.config/nemoclaw"
DEFAULT_GATEWAY="nemoclaw"
PROVIDERS=("nvidia-nim" "vllm-local" "ollama-local" "nvidia-ncp" "nim-local")
OPEN_SHELL_INSTALL_PATHS=("/usr/local/bin/openshell")

ASSUME_YES=false
KEEP_OPEN_SHELL=false

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--yes] [--keep-openshell]

Options:
  --yes             Skip the confirmation prompt
  --keep-openshell  Leave the openshell binary installed
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --keep-openshell)
      KEEP_OPEN_SHELL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

confirm() {
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi

  echo ""
  warn "This will remove all OpenShell sandboxes, NemoClaw-managed gateway/providers,"
  warn "and local state under ~/.nemoclaw, ~/.config/openshell, and ~/.config/nemoclaw."
  warn "It will not uninstall Docker, Ollama, npm, Node.js, or other shared tooling."
  printf "Continue? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) info "Aborted."; exit 0 ;;
  esac
}

run_optional() {
  local description="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    info "$description"
  else
    warn "$description skipped"
  fi
}

remove_path() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -rf "$path"
    info "Removed $path"
  fi
}

remove_file_with_optional_sudo() {
  local path="$1"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if [ -w "$path" ] || [ -w "$(dirname "$path")" ]; then
    rm -f "$path"
  else
    sudo rm -f "$path"
  fi
  info "Removed $path"
}

stop_helper_services() {
  if [ -x "$SCRIPT_DIR/scripts/start-services.sh" ]; then
    run_optional "Stopped NemoClaw helper services" "$SCRIPT_DIR/scripts/start-services.sh" --stop
  fi

  for dir in /tmp/nemoclaw-services-*; do
    [ -e "$dir" ] || continue
    rm -rf "$dir"
    info "Removed $dir"
  done
}

remove_openshell_resources() {
  if ! command -v openshell > /dev/null 2>&1; then
    warn "openshell not found; skipping gateway/provider/sandbox cleanup."
    return 0
  fi

  run_optional "Deleted all OpenShell sandboxes" openshell sandbox delete --all

  for provider in "${PROVIDERS[@]}"; do
    run_optional "Deleted provider '${provider}'" openshell provider delete "$provider"
  done

  run_optional "Destroyed gateway '${DEFAULT_GATEWAY}'" openshell gateway destroy -g "$DEFAULT_GATEWAY"
}

remove_nemoclaw_cli() {
  if command -v npm > /dev/null 2>&1; then
    npm unlink -g nemoclaw > /dev/null 2>&1 || true
    if npm uninstall -g nemoclaw > /dev/null 2>&1; then
      info "Removed global nemoclaw npm package"
    else
      warn "Global nemoclaw npm package not found or already removed"
    fi
  else
    warn "npm not found; skipping nemoclaw npm uninstall."
  fi
}

remove_nemoclaw_state() {
  remove_path "$NEMOCLAW_STATE_DIR"
  remove_path "$OPENSHELL_CONFIG_DIR"
  remove_path "$NEMOCLAW_CONFIG_DIR"
}

remove_openshell_binary() {
  if [ "$KEEP_OPEN_SHELL" = true ]; then
    info "Keeping openshell binary as requested."
    return 0
  fi

  local removed=false
  local current_path=""
  if command -v openshell > /dev/null 2>&1; then
    current_path="$(command -v openshell)"
  fi

  for path in "${OPEN_SHELL_INSTALL_PATHS[@]}"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      remove_file_with_optional_sudo "$path"
      removed=true
    fi
  done

  if [ "$removed" = false ] && [ -n "$current_path" ]; then
    warn "openshell is installed at $current_path; leaving it in place."
  elif [ "$removed" = false ]; then
    warn "openshell binary not found in installer-managed locations."
  fi
}

main() {
  confirm

  info "Stopping NemoClaw helper services..."
  stop_helper_services

  info "Removing OpenShell resources created for NemoClaw..."
  remove_openshell_resources

  info "Removing global nemoclaw install..."
  remove_nemoclaw_cli

  info "Removing NemoClaw state..."
  remove_nemoclaw_state

  info "Removing openshell binary..."
  remove_openshell_binary

  echo ""
  info "Uninstall complete."
}

main "$@"
