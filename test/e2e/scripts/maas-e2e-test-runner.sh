#!/bin/bash
set -euo pipefail

MODE="${MODE:-ci}"
SKIP_IDP_SETUP="${SKIP_IDP_SETUP:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERROR_COUNT=0

# Source shared logging library
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

# Record an error and continue (script fails at end if ERROR_COUNT > 0)
record_error() {
    log_error "$1"
    ERROR_COUNT=$((ERROR_COUNT + 1))
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        *) log_error "Usage: $0 [--mode <ci|dev>]"; exit 1 ;;
    esac
done

[[ "$MODE" != "ci" && "$MODE" != "dev" ]] && { log_error "Invalid mode '$MODE'"; exit 1; }

# From here on, do not exit on failure; collect errors and fail at end
set +e
# ================================
# Main
# ================================

log_banner "MaaS E2E Test "

log_step "Deployment Configuration"
log_kv "Mode" "$MODE"
log_kv "Skip IDP Setup" "$SKIP_IDP_SETUP"
if [[ "$MODE" == "ci" ]]; then
    log_kv "IDP steps" "run (ci mode; SKIP_IDP_SETUP ignored;)"
elif [[ "$MODE" == "dev" && "$SKIP_IDP_SETUP" != "true" ]]; then
    log_kv "IDP steps" "run (dev, IDP setup enabled)"
else
    log_kv "IDP steps" "skipped (dev, SKIP_IDP_SETUP=true)"
fi

# When true, we run IDP setup, admin setup, and tier mapping (and need $USERS).
# mode=ci: always run IDP steps (after sourcing runtime_env for $USERS). SKIP_IDP_SETUP is ignored.
# mode=dev + SKIP_IDP_SETUP=false: run IDP setup and all IDP steps.
# mode=dev + SKIP_IDP_SETUP=true: skip all IDP steps, run only deployment/validation.
RUN_IDP_STEPS=false
if [[ "$MODE" == "ci" ]]; then
    if [[ -z "${SHARED_DIR:-}" ]]; then
        log_error "CI mode requires SHARED_DIR (e.g. set by Prow). Run with --mode dev for local testing."
        exit 1
    fi
    source "${SHARED_DIR}/runtime_env"
    if [[ -z "${USERS:-}" ]]; then
        log_error "CI mode: OpenShift \$USERS not set (expected from SHARED_DIR/runtime_env)"
        exit 1
    fi
    log_success "USERS setup complete (from runtime_env)"
    RUN_IDP_STEPS=true
elif [[ "$MODE" == "dev" && "$SKIP_IDP_SETUP" != "true" ]]; then
    log_step "Setting up HTPasswd identity provider"
    source "${SCRIPT_DIR}/setup-idp-openshift.sh" --fixed-passwords
    if [[ -z "${USERS:-}" ]]; then
        log_error "OpenShift \$USERS not set after IDP setup"
        exit 1
    fi
    log_success "USERS setup complete"
    RUN_IDP_STEPS=true
else
    log_info "Skipping IDP setup (mode=dev, SKIP_IDP_SETUP=true)"
fi

# Grant cluster-admin role to a user.
make_user_admin() {
    local username="$1"
    log_info "Granting cluster-admin role to ${username}"
    local err
    err=$(mktemp)
    if oc adm policy add-cluster-role-to-user cluster-admin "$username" 2> "$err"; then
        grep -v "not found" "$err" >&2 || true
        rm -f "$err"
        log_success "${username} is now a cluster-admin"
    else
        cat "$err" >&2
        rm -f "$err"
        log_error "Failed to grant cluster-admin role to ${username}"
        return 1
    fi
}

if [[ "$RUN_IDP_STEPS" == "true" ]]; then
    log_step "Setup MaaS Admin"
    first_user="$(echo "$USERS" | cut -d',' -f1 | cut -d':' -f1)"
    make_user_admin "$first_user"
    log_success "MAAS Admin set: $first_user"
fi

get_users_from_csv() {
    echo "$USERS" | tr ',' '\n' | cut -d':' -f1
}

# Tier membership: derived from $USERS by position (first 2=enterprise, next 2=premium, rest=free).
# Override via env: TIER_ENTERPRISE_USERS, TIER_PREMIUM_USERS, TIER_FREE_USERS (space-separated).
_set_tier_users_from_env() {
    local user_array
    user_array=( $(get_users_from_csv) )
    local n=${#user_array[@]}

    if [[ -z "${TIER_ENTERPRISE_USERS:-}" && $n -ge 2 ]]; then
        TIER_ENTERPRISE_USERS="${user_array[0]} ${user_array[1]}"
    fi
    if [[ -z "${TIER_PREMIUM_USERS:-}" && $n -ge 4 ]]; then
        TIER_PREMIUM_USERS="${user_array[2]} ${user_array[3]}"
    fi
    if [[ -z "${TIER_FREE_USERS:-}" && $n -ge 5 ]]; then
        TIER_FREE_USERS="${user_array[@]:4}"
    fi
}

FREE_GROUP="tier-free-users"
PREMIUM_GROUP="tier-premium-users"
ENTERPRISE_GROUP="tier-enterprise-users"

map_users_to_tiers() {
    _set_tier_users_from_env

    log_info "Creating $FREE_GROUP, $PREMIUM_GROUP, $ENTERPRISE_GROUP groups"
    oc adm groups new $FREE_GROUP || true
    oc adm groups new $PREMIUM_GROUP || true
    oc adm groups new $ENTERPRISE_GROUP || true

    if [[ -n "${TIER_ENTERPRISE_USERS:-}" ]]; then
        log_info "Adding enterprise users to maas-enterprise: ${TIER_ENTERPRISE_USERS}"
        oc adm groups add-users $ENTERPRISE_GROUP ${TIER_ENTERPRISE_USERS}
    fi

    if [[ -n "${TIER_PREMIUM_USERS:-}" ]]; then
        log_info "Adding premium users to maas-premium: ${TIER_PREMIUM_USERS}"
        oc adm groups add-users $PREMIUM_GROUP ${TIER_PREMIUM_USERS}
    fi

    if [[ -n "${TIER_FREE_USERS:-}" ]]; then
        log_info "Adding free users to maas-free: ${TIER_FREE_USERS}"
        oc adm groups add-users $FREE_GROUP ${TIER_FREE_USERS}
    fi

    log_success "Users mapped to respective groups"
    log_info "Group memberships:"
    log_info "  $ENTERPRISE_GROUP: $(oc get group $ENTERPRISE_GROUP -o jsonpath='{.users[*]}' 2>/dev/null)"
    log_info "  $PREMIUM_GROUP:  $(oc get group $PREMIUM_GROUP -o jsonpath='{.users[*]}' 2>/dev/null)"
    log_info "  $FREE_GROUP:     $(oc get group $FREE_GROUP -o jsonpath='{.users[*]}' 2>/dev/null)"
}

# First user from each tier (for smoke tests). Output: space-separated list.
get_users_from_tiers() {
    local first_enterprise first_premium first_free
    first_enterprise=$(oc get group $ENTERPRISE_GROUP -o jsonpath='{.users[0]}' 2>/dev/null)
    first_premium=$(oc get group $PREMIUM_GROUP -o jsonpath='{.users[0]}' 2>/dev/null)
    first_free=$(oc get group $FREE_GROUP -o jsonpath='{.users[0]}' 2>/dev/null)
    local list=""
    [[ -n "${first_enterprise:-}" ]] && list="${first_enterprise}"
    [[ -n "${first_premium:-}" ]] && list="${list:+$list }${first_premium}"
    [[ -n "${first_free:-}" ]] && list="${list:+$list }${first_free}"
    echo "$list"
}

if [[ "$RUN_IDP_STEPS" == "true" ]]; then
    log_step "Map users to respective groups"
    map_users_to_tiers
    log_success "Users mapped to respective groups"

    log_step "Get users from tiers for Validation"
    USERS_TO_TEST=$(get_users_from_tiers)
    log_success "Users to test: ${USERS_TO_TEST:-(none)}"
else
    log_step "Get users from tiers for Validation"
    USERS_TO_TEST=$(oc whoami)
    log_success "IDP skipped; using current user for tests: $USERS_TO_TEST"
fi
export USERS_TO_TEST

if [[ -z "${USERS_TO_TEST:-}" ]]; then
    record_error "USERS_TO_TEST is not set or is empty; cannot run deployment and validation"
else
    log_success "USERS_TO_TEST is set and ready for deployment and validation"
fi

log_step "Running MaaS Deployment and Validation"
if ! "${SCRIPT_DIR}/prow_run_smoke_test.sh"; then
    record_error "Smoke test failed"
else
    log_success "MaaS Deployment and Validation completed successfully"
fi

if [[ $ERROR_COUNT -gt 0 ]]; then
    log_error "MaaS E2E Test completed with ${ERROR_COUNT} error(s)"
    exit 1
fi
log_success "MaaS E2E Test Completed Successfully"