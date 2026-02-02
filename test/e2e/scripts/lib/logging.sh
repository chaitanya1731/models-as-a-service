#!/usr/bin/env bash
# ==========================================================
# Shared Logging Library for MaaS E2E Scripts
# ==========================================================
# Source this file to get consistent logging across scripts.
#
# USAGE:
#   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/logging.sh"
#   # or with absolute path:
#   source /path/to/lib/logging.sh
#
# FUNCTIONS:
#   log_info "message"      - Blue INFO message
#   log_success "message"   - Green success with checkmark
#   log_warn "message"      - Yellow warning
#   log_error "message"     - Red error (to stderr)
#   log_step "title"        - Bold section header
#   log_debug "message"     - Debug (only if VERBOSE=1)
#   log_banner "title"      - Boxed banner header
#
# CONFIGURATION:
#   VERBOSE=1               - Enable debug output
#   NO_COLOR=1              - Disable colors
#   LOG_PREFIX="[script]"   - Add prefix to all messages
# ==========================================================

# Prevent double-sourcing
[[ -n "${_LOGGING_SH_LOADED:-}" ]] && return 0
_LOGGING_SH_LOADED=1

# --- Default Configuration ---
: "${VERBOSE:=0}"
: "${NO_COLOR:=0}"
: "${LOG_PREFIX:=}"

# --- Color Codes ---
# Auto-disable if not terminal or NO_COLOR is set
if [[ -t 1 && "$NO_COLOR" != "1" ]]; then
  _CLR_RED='\033[0;31m'
  _CLR_GREEN='\033[0;32m'
  _CLR_YELLOW='\033[0;33m'
  _CLR_BLUE='\033[0;34m'
  _CLR_CYAN='\033[0;36m'
  _CLR_MAGENTA='\033[0;35m'
  _CLR_BOLD='\033[1m'
  _CLR_DIM='\033[2m'
  _CLR_NC='\033[0m'
else
  _CLR_RED='' _CLR_GREEN='' _CLR_YELLOW='' _CLR_BLUE=''
  _CLR_CYAN='' _CLR_MAGENTA='' _CLR_BOLD='' _CLR_DIM='' _CLR_NC=''
fi

# --- Export colors for use in scripts ---
# These can be used directly in echo -e statements
export CLR_RED="$_CLR_RED"
export CLR_GREEN="$_CLR_GREEN"
export CLR_YELLOW="$_CLR_YELLOW"
export CLR_BLUE="$_CLR_BLUE"
export CLR_CYAN="$_CLR_CYAN"
export CLR_MAGENTA="$_CLR_MAGENTA"
export CLR_BOLD="$_CLR_BOLD"
export CLR_DIM="$_CLR_DIM"
export CLR_NC="$_CLR_NC"

# ==========================================================
# Core Logging Functions
# ==========================================================

# Get current timestamp
_log_timestamp() {
  date '+%H:%M:%S'
}

# Internal log formatter
_log_format() {
  local level="$1"
  local color="$2"
  local icon="$3"
  shift 3
  local prefix=""
  [[ -n "$LOG_PREFIX" ]] && prefix="${_CLR_DIM}${LOG_PREFIX}${_CLR_NC} "
  echo -e "${_CLR_BLUE}[$(_log_timestamp)]${_CLR_NC} ${prefix}${color}${icon}${_CLR_NC} $*"
}

# Info message (general information)
log_info() {
  _log_format "INFO" "$_CLR_CYAN" "INFO " "$@"
}

# Success message (operation completed)
log_success() {
  _log_format "OK" "$_CLR_GREEN" "✔ OK " "$@"
}

# Warning message (non-fatal issue)
log_warn() {
  _log_format "WARN" "$_CLR_YELLOW" "⚠ WARN" "$@"
}

# Error message (to stderr)
log_error() {
  _log_format "ERROR" "$_CLR_RED" "✖ ERR " "$@" >&2
}

# Debug message (only when VERBOSE=1)
log_debug() {
  [[ "$VERBOSE" != "1" ]] && return 0
  _log_format "DEBUG" "$_CLR_DIM" "DEBUG" "$@"
}

# Section header (visual separator)
log_step() {
  echo -e "\n${_CLR_BOLD}━━━ $* ━━━${_CLR_NC}"
}

# Sub-step (indented info)
log_substep() {
  echo -e "    ${_CLR_CYAN}→${_CLR_NC} $*"
}

# Banner header (boxed title)
log_banner() {
  local title="$1"
  local width=${2:-60}
  local padding=$(( (width - ${#title} - 2) / 2 ))
  local pad_str=$(printf '%*s' "$padding" '' | tr ' ' ' ')
  
  echo ""
  echo -e "${_CLR_BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${_CLR_NC}"
  echo -e "${_CLR_BOLD}║${pad_str} ${title} ${pad_str}║${_CLR_NC}"
  echo -e "${_CLR_BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${_CLR_NC}"
}

# ==========================================================
# Progress & Status Functions
# ==========================================================

# Start a task (shows "..." indicator)
log_task_start() {
  echo -en "${_CLR_BLUE}[$(_log_timestamp)]${_CLR_NC} ${_CLR_CYAN}...${_CLR_NC}   $* "
}

# End a task with result
log_task_end() {
  local status="${1:-ok}"
  case "$status" in
    ok|success) echo -e "${_CLR_GREEN}✔${_CLR_NC}" ;;
    fail|error) echo -e "${_CLR_RED}✖${_CLR_NC}" ;;
    skip)       echo -e "${_CLR_YELLOW}⊘${_CLR_NC}" ;;
    warn)       echo -e "${_CLR_YELLOW}⚠${_CLR_NC}" ;;
    *)          echo -e "${_CLR_DIM}?${_CLR_NC}" ;;
  esac
}

# Show a spinner while a command runs (usage: run_with_spinner "message" command args...)
run_with_spinner() {
  local msg="$1"
  shift
  local pid
  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  
  # Start command in background
  "$@" &
  pid=$!
  
  # Show spinner
  echo -en "${_CLR_BLUE}[$(_log_timestamp)]${_CLR_NC} ${_CLR_CYAN}...${_CLR_NC}   $msg "
  while kill -0 $pid 2>/dev/null; do
    echo -en "\b${spin_chars:$i:1}"
    i=$(( (i + 1) % ${#spin_chars} ))
    sleep 0.1
  done
  
  # Check result
  if wait $pid; then
    echo -e "\b${_CLR_GREEN}✔${_CLR_NC}"
    return 0
  else
    echo -e "\b${_CLR_RED}✖${_CLR_NC}"
    return 1
  fi
}

# ==========================================================
# Utility Functions
# ==========================================================

# Print a horizontal rule
log_hr() {
  local char="${1:-─}"
  local width="${2:-60}"
  echo -e "${_CLR_DIM}$(printf "${char}%.0s" $(seq 1 $width))${_CLR_NC}"
}

# Print key-value pair (formatted)
log_kv() {
  local key="$1"
  local value="$2"
  local key_width="${3:-20}"
  printf "  ${_CLR_BOLD}%-${key_width}s${_CLR_NC} %s\n" "$key:" "$value"
}

# Print a list item
log_item() {
  echo -e "    ${_CLR_CYAN}•${_CLR_NC} $*"
}

# Confirmation prompt (returns 0 for yes, 1 for no)
log_confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-n}"
  local yn_hint="[y/N]"
  [[ "$default" == "y" ]] && yn_hint="[Y/n]"
  
  echo -en "${_CLR_YELLOW}?${_CLR_NC} $prompt $yn_hint "
  read -r answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

# ==========================================================
# Detect if script is sourced (portable bash + zsh)
# ==========================================================
is_sourced() {
  if [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
    [[ "$ZSH_EVAL_CONTEXT" == *:file:* ]] && return 0
  elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0
  fi
  return 1
}

# ==========================================================
# Self-test (run directly to see examples)
# ==========================================================
_logging_demo() {
  log_banner "Logging Library Demo"
  
  log_step "Log Levels"
  log_info "This is an informational message"
  log_success "Operation completed successfully"
  log_warn "This is a warning message"
  log_error "This is an error message"
  VERBOSE=1 log_debug "This is a debug message (VERBOSE=1)"
  
  log_step "Formatting"
  log_substep "This is a sub-step"
  log_item "This is a list item"
  log_item "Another list item"
  
  echo ""
  log_kv "Cluster" "api.example.com"
  log_kv "User" "admin"
  log_kv "Namespace" "default"
  
  log_step "Task Progress"
  log_task_start "Checking something"
  sleep 0.5
  log_task_end ok
  
  log_task_start "Something that failed"
  sleep 0.3
  log_task_end fail
  
  log_hr
  log_info "Demo complete!"
}

# Run demo if executed directly
if ! is_sourced; then
  _logging_demo
fi

