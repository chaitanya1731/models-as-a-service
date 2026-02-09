#!/usr/bin/env bash
# ==========================================================
# OpenShift HTPasswd IDP Setup
# ==========================================================
# Emulates Prow cluster IDP configuration for local testing.
# Creates testuser-1 through testuser-N with edit role.
#
# USAGE:
#   source ./setup-idp-openshift.sh                      # create users on OCP
#   source ./setup-idp-openshift.sh --dry-run            # only export $USERS
#   source ./setup-idp-openshift.sh --fixed-passwords    # use pass-1, pass-2...
#   source ./setup-idp-openshift.sh --fixed-passwords=secret  # use secret-1...
#   FIXED_PASSWORDS=secret source ./setup-idp-openshift.sh    # same via env
#   ./setup-idp-openshift.sh --delete                    # cleanup OCP artifacts
#   source ./setup-idp-openshift.sh --show-login         # show login example
#   source ./setup-idp-openshift.sh --verbose            # enable verbose output
#   ./setup-idp-openshift.sh --help                      # show help
#
# OUTPUT:
#   Exports $USERS as: testuser-1:pass1,testuser-2:pass2,...
# ==========================================================

# --- Default Configuration ---
: "${IDP_NAME:=maas-test-htpasswd}"
: "${HTPASSWD_SECRET_NAME:=${IDP_NAME}-secret}"
: "${NUM_USERS:=10}"
: "${BCRYPT_COST:=10}"  # bcrypt cost factor (10 is fast, 12 is more secure)
: "${OAUTH_ROLLOUT_TIMEOUT:=300}"
: "${RETRY_COUNT:=3}"
: "${RETRY_DELAY:=5}"

# --- Source Shared Logging Library ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${_SCRIPT_DIR}/lib/logging.sh"

# Aliases for backward compatibility (used in print_summary)
BOLD="$CLR_BOLD" NC="$CLR_NC" GREEN="$CLR_GREEN" YELLOW="$CLR_YELLOW" CYAN="$CLR_CYAN" RED="$CLR_RED"

# --- Parse Arguments ---
DRY_RUN=0
DELETE_MODE=0
SHOW_LOGIN=0
VERBOSE=0
SHOW_HELP=0

# Always reset FIXED_PASSWORDS to prevent stale values from previous sourced runs
# Use --fixed-passwords flag or inline: FIXED_PASSWORDS=x source script.sh
FIXED_PASSWORDS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)           DRY_RUN=1 ;;
    --delete)            DELETE_MODE=1 ;;
    --show-login)        SHOW_LOGIN=1 ;;
    --verbose|-v)        VERBOSE=1 ;;
    --help|-h)           SHOW_HELP=1 ;;
    --fixed-passwords)   FIXED_PASSWORDS="pass" ;;
    --fixed-passwords=*) FIXED_PASSWORDS="${arg#*=}" ;;
    --num-users=*)       NUM_USERS="${arg#*=}" ;;
  esac
done

# --- Strict Mode (only when NOT sourced, to avoid killing user's shell) ---
is_sourced || set -euo pipefail

# ==========================================================
# Utility Functions
# ==========================================================

show_help() {
  cat << 'EOF'
OpenShift HTPasswd IDP Setup

USAGE:
  source ./setup-idp-openshift.sh [OPTIONS]

OPTIONS:
  --dry-run              Generate users but don't modify cluster
  --delete               Remove IDP and cleanup users
  --fixed-passwords      Use predictable passwords (pass-1, pass-2, ...)
  --fixed-passwords=PREFIX  Use PREFIX-1, PREFIX-2, ... as passwords
  --num-users=N          Create N users (default: 10)
  --show-login           Show login command examples
  --verbose, -v          Enable verbose output
  --help, -h             Show this help message

ENVIRONMENT VARIABLES:
  IDP_NAME               IDP name (default: maas-test-htpasswd)
  HTPASSWD_SECRET_NAME   Secret name (default: ${IDP_NAME}-secret)
  NUM_USERS              Number of users to create (default: 10)
  FIXED_PASSWORDS        Password prefix (alternative to --fixed-passwords)
  OAUTH_ROLLOUT_TIMEOUT  OAuth rollout timeout in seconds (default: 300)

EXAMPLES:
  # Create 10 users with random passwords
  source ./setup-idp-openshift.sh

  # Create 5 users with predictable passwords
  source ./setup-idp-openshift.sh --fixed-passwords --num-users=5

  # Dry run - just export $USERS without cluster changes
  source ./setup-idp-openshift.sh --dry-run --fixed-passwords

  # Cleanup everything
  ./setup-idp-openshift.sh --delete

OUTPUT:
  Exports $USERS as: testuser-1:pass1,testuser-2:pass2,...
EOF
}

# Retry a command with exponential backoff
retry_cmd() {
  local max_attempts=$1
  local delay=$2
  shift 2
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    log_debug "Attempt $attempt/$max_attempts: $*"
    if "$@"; then
      return 0
    fi
    
    if [[ $attempt -lt $max_attempts ]]; then
      log_warn "Attempt $attempt failed, retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    fi
    ((attempt++))
  done
  
  log_error "Command failed after $max_attempts attempts: $*"
  return 1
}

# Check if logged into OpenShift cluster
check_cluster_login() {
  if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift cluster"
    log_info "Run: oc login <cluster-url>"
    return 1
  fi
  
  local user cluster
  user=$(oc whoami 2>/dev/null)
  cluster=$(oc whoami --show-server 2>/dev/null | sed 's|https://||' | cut -d: -f1)
  log_success "Logged in as ${BOLD}$user${NC} on ${BOLD}$cluster${NC}"
  return 0
}

# Verify a Kubernetes resource exists
verify_resource() {
  local resource=$1
  local name=$2
  local namespace=${3:-}
  
  if [[ -n "$namespace" ]]; then
    if oc get "$resource" "$name" -n "$namespace" >/dev/null 2>&1; then
      log_debug "Verified: $resource/$name in $namespace exists"
      return 0
    fi
  else
    if oc get "$resource" "$name" >/dev/null 2>&1; then
      log_debug "Verified: $resource/$name exists"
      return 0
    fi
  fi
  
  log_debug "Verification failed for $resource/$name"
  return 1
}

# ==========================================================
# Dependency Check
# ==========================================================

check_dependencies() {
  local missing=()
  
  for cmd in openssl htpasswd oc; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    log_info "Install missing dependencies and retry"
    return 1
  fi
  
  log_debug "All dependencies available: openssl, htpasswd, oc"
  return 0
}

# ==========================================================
# Core Functions
# ==========================================================

generate_users() {
  log_step "Generating User Credentials"
  
  USERS_CSV=""
  local password_type="random"
  [[ -n "$FIXED_PASSWORDS" ]] && password_type="fixed (${FIXED_PASSWORDS}-N)"
  
  log_info "Creating $NUM_USERS users with $password_type passwords"
  
  for ((i=1; i<=NUM_USERS; i++)); do
    local username="testuser-${i}"
    local password=""
    if [[ -n "$FIXED_PASSWORDS" ]]; then
      password="${FIXED_PASSWORDS}-${i}"
    else
      password=$(openssl rand -hex 6)
    fi
    [[ -n "$USERS_CSV" ]] && USERS_CSV+=","
    USERS_CSV+="${username}:${password}"
  done
  
  log_success "Generated credentials for $NUM_USERS users"
  log_debug "Users: testuser-1 through testuser-$NUM_USERS"
}

create_htpasswd_secret() {
  log_step "Creating HTPasswd Secret"
  
  local htpasswd_data=""
  local entry username password
  local count=0
  
  # Parse USERS_CSV (portable for bash + zsh)
  IFS=',' read -r -A entries <<< "$USERS_CSV" 2>/dev/null || IFS=',' read -r -a entries <<< "$USERS_CSV"
  
  log_info "Generating bcrypt hashes for ${#entries[@]} users (this may take a moment)..."
  
  for entry in "${entries[@]}"; do
    username="${entry%%:*}"
    password="${entry#*:}"
    htpasswd_data+=$(printf '%s\n' "$password" | htpasswd -nB -C "$BCRYPT_COST" -i "$username")$'\n'
    ((count++))
    # Progress indicator for large user counts
    if [[ $((count % 5)) -eq 0 ]]; then
      log_debug "Processed $count/${#entries[@]} users"
    fi
  done
  
  log_info "Creating secret ${BOLD}$HTPASSWD_SECRET_NAME${NC} in openshift-config"
  
  if ! echo "$htpasswd_data" | oc create secret generic "$HTPASSWD_SECRET_NAME" \
      --from-file=htpasswd=/dev/stdin \
      -n openshift-config --dry-run=client -o yaml | oc apply -f -; then
    log_error "Failed to create htpasswd secret"
    return 1
  fi
  
  # Verify secret was created (small delay for API propagation)
  sleep 1
  if verify_resource secret "$HTPASSWD_SECRET_NAME" openshift-config; then
    log_success "Secret created successfully"
  else
    log_error "Secret verification failed"
    log_info "Debug: Running 'oc get secret $HTPASSWD_SECRET_NAME -n openshift-config'"
    oc get secret "$HTPASSWD_SECRET_NAME" -n openshift-config 2>&1 || true
    return 1
  fi
}

configure_oauth() {
  log_step "Configuring OAuth Identity Provider"
  
  # Check if OAuth resource exists
  if ! oc get oauth cluster &>/dev/null; then
    log_info "Creating new OAuth configuration with HTPasswd provider"
    
    if ! oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: ${IDP_NAME}
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: ${HTPASSWD_SECRET_NAME}
EOF
    then
      log_error "Failed to create OAuth configuration"
      return 1
    fi
    
    log_success "OAuth configuration created"
    return 0
  fi
  
  # Check if our IDP already exists
  local existing_idps
  existing_idps=$(oc get oauth cluster -o jsonpath="{.spec.identityProviders[*].name}" 2>/dev/null || echo "")
  
  if echo "$existing_idps" | grep -qw "${IDP_NAME}"; then
    log_info "IDP '${IDP_NAME}' already configured, secret updated"
    log_success "OAuth configuration unchanged (IDP exists)"
    return 0
  fi
  
  # Add our IDP to existing configuration
  log_info "Adding HTPasswd provider '${IDP_NAME}' to existing OAuth"
  log_debug "Existing IDPs: $existing_idps"
  
  if ! oc patch oauth cluster --type=json -p="[{
    \"op\": \"add\",
    \"path\": \"/spec/identityProviders/-\",
    \"value\": {
      \"name\": \"${IDP_NAME}\",
      \"mappingMethod\": \"claim\",
      \"type\": \"HTPasswd\",
      \"htpasswd\": {
        \"fileData\": {
          \"name\": \"${HTPASSWD_SECRET_NAME}\"
        }
      }
    }
  }]"; then
    log_warn "OAuth patch returned non-zero (may still have succeeded)"
  fi
  
  # Verify IDP was added
  sleep 2
  if oc get oauth cluster -o jsonpath="{.spec.identityProviders[*].name}" 2>/dev/null | grep -qw "${IDP_NAME}"; then
    log_success "IDP '${IDP_NAME}' added to OAuth configuration"
  else
    log_warn "Could not verify IDP was added - check manually"
  fi
}

wait_for_oauth() {
  log_step "Waiting for OAuth Rollout"
  
  log_info "Restarting OAuth deployment..."
  if ! oc -n openshift-authentication rollout restart deployment/oauth-openshift 2>/dev/null; then
    log_warn "Could not restart OAuth deployment (may not be needed)"
  fi
  
  log_info "Waiting for rollout to complete (timeout: ${OAUTH_ROLLOUT_TIMEOUT}s)..."
  
  local start_time=$SECONDS
  if oc -n openshift-authentication rollout status deployment/oauth-openshift --timeout="${OAUTH_ROLLOUT_TIMEOUT}s" 2>/dev/null; then
    local duration=$((SECONDS - start_time))
    log_success "OAuth rollout completed in ${duration}s"
  else
    log_warn "OAuth rollout status check timed out (authentication may still work)"
  fi
  
  # Additional stabilization delay
  log_info "Allowing OAuth pods to stabilize..."
  sleep 5
  
  # Verify OAuth pods are ready
  local ready_pods
  ready_pods=$(oc get pods -n openshift-authentication -l app=oauth-openshift -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -c Running || echo 0)
  
  if [[ "$ready_pods" -gt 0 ]]; then
    log_success "OAuth pods running: $ready_pods"
  else
    log_warn "No running OAuth pods detected - verify manually"
  fi
}

grant_user_roles() {
  log_step "Granting User Permissions"
  
  log_info "Adding 'view' cluster role to $NUM_USERS users..."
  
  local success=0
  local failed=0
  
  for ((i=1; i<=NUM_USERS; i++)); do
    if oc adm policy add-cluster-role-to-user view "testuser-${i}" &>/dev/null; then
      ((success++))
    else
      ((failed++))
      log_debug "Failed to grant role to testuser-${i}"
    fi
  done
  
  if [[ $failed -eq 0 ]]; then
    log_success "Granted view role to all $success users"
  else
    log_warn "Granted role to $success users, $failed failed (may already exist)"
  fi
}

delete_idp() {
  log_step "Cleanup Mode"
  
  # Always unset local USERS var
  unset USERS 2>/dev/null || true
  log_success "Unset \$USERS environment variable"
  
  # Check cluster login
  if ! oc whoami &>/dev/null; then
    log_warn "Not logged in to cluster, skipping cluster cleanup"
    return 0
  fi
  
  log_info "Removing IDP '${IDP_NAME}' resources..."
  
  # Delete secret
  if oc delete secret "$HTPASSWD_SECRET_NAME" -n openshift-config &>/dev/null; then
    log_success "Deleted secret: $HTPASSWD_SECRET_NAME"
  else
    log_debug "Secret not found or already deleted"
  fi
  
  # Remove users, identities, and roles
  log_info "Removing $NUM_USERS user accounts and identities..."
  
  local removed=0
  for ((i=1; i<=NUM_USERS; i++)); do
    oc adm policy remove-cluster-role-from-user edit "testuser-${i}" &>/dev/null || true
    oc delete user "testuser-${i}" &>/dev/null && ((removed++)) || true
    oc delete identity "${IDP_NAME}:testuser-${i}" &>/dev/null || true
  done
  
  log_success "Removed $removed user accounts"
  
  echo ""
  log_warn "Manual step required: Remove '${IDP_NAME}' from OAuth if needed"
  log_info "Run: oc edit oauth cluster"
  
  echo ""
  log_success "Cleanup completed"
}

print_summary() {
  log_step "Setup Summary"
  
  echo ""
  echo -e "  ${BOLD}Configuration:${NC}"
  echo -e "    • Users created:  ${GREEN}$NUM_USERS${NC}"
  echo -e "    • IDP name:       ${CYAN}$IDP_NAME${NC}"
  echo -e "    • Secret:         ${CYAN}$HTPASSWD_SECRET_NAME${NC}"
  
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "    • Mode:           ${YELLOW}dry-run (no cluster changes)${NC}"
  else
    echo -e "    • Mode:           ${GREEN}applied to cluster${NC}"
  fi
  
  echo ""
  echo -e "  ${BOLD}Status:${NC}"
  
  # Check if running sourced or directly
  if is_sourced; then
    echo -e "    ${GREEN}✔${NC}  Credentials exported to ${BOLD}\$USERS${NC}"
  else
    echo -e "    ${YELLOW}⚠${NC}  Run with 'source' to export \$USERS to your shell"
  fi
  
  if [[ "$SHOW_LOGIN" == "1" ]]; then
    echo ""
    echo -e "  ${BOLD}Login Example:${NC}"
    echo -e "    ${CYAN}oc login \$(oc whoami --show-server) -u testuser-1 -p <password>${NC}"
    echo ""
    echo -e "  ${BOLD}Get User Password:${NC}"
    echo -e "    ${CYAN}echo \"\$USERS\" | tr ',' '\\n' | grep testuser-1${NC}"
  fi
  
  echo ""
  echo -e "  ${BOLD}Verification Commands:${NC}"
  echo -e "    ${CYAN}oc get secret $HTPASSWD_SECRET_NAME -n openshift-config${NC}"
  echo -e "    ${CYAN}oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'${NC}"
  
  echo ""
  return 0
}

# ==========================================================
# Main
# ==========================================================

main() {
  # Show help if requested
  if [[ "$SHOW_HELP" == "1" ]]; then
    show_help
    return 0
  fi
  
  # Check dependencies first
  check_dependencies || return 1
  
  # Handle delete mode
  if [[ "$DELETE_MODE" == "1" ]]; then
    delete_idp
    return 0
  fi
  
  # Validate configuration
  if ! [[ "$NUM_USERS" =~ ^[0-9]+$ ]] || [[ "$NUM_USERS" -lt 1 ]]; then
    log_error "Invalid NUM_USERS: $NUM_USERS (must be positive integer)"
    return 1
  fi

  echo ""
  echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        OpenShift IDP Setup for MaaS                    ║${NC}"
  echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
  
  # Generate users (always needed for $USERS export)
  generate_users
  
  # Apply to cluster (unless dry-run)
  if [[ "$DRY_RUN" != "1" ]]; then
    check_cluster_login || return 1
    create_htpasswd_secret || return 1
    configure_oauth || return 1
    wait_for_oauth
    grant_user_roles
  else
    log_step "Dry Run Mode"
    log_info "Skipping cluster modifications"
  fi
  
  # Export credentials
  export USERS="$USERS_CSV"
  
  # Print summary
  print_summary
}

# Run main (wrapped to prevent killing shell when sourced)
if is_sourced; then
  # When sourced, catch errors gracefully
  main || log_error "Script encountered an error (exit code: $?)"
else
  # When run directly, exit with main's return code
  main
  exit $?
fi
