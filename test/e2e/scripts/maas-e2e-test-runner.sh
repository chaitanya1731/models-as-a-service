#!/bin/bash
set -euo pipefail

MODE="${MODE:-dev}"
SKIP_IDP_SETUP="${SKIP_IDP_SETUP:-true}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging library
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        *) log_error "Usage: $0 [--mode <ci|dev>]"; exit 1 ;;
    esac
done

[[ "$MODE" != "ci" && "$MODE" != "dev" ]] && { log_error "Invalid mode '$MODE'"; exit 1; }



run_ci_mode() { 
    log_step "Running in CI"
    # Assume users are already created and exported to $USERS env
    
    if [[ -z "${USERS:-}" ]]; then
        log_error "\$USERS environment variable is not set"
        exit 1
    fi

    log_step "Running MaaS e2e Smoke Test"
    if ! "${SCRIPT_DIR}/prow_run_smoke_test.sh"; then
        log_error "Smoke test failed"
        exit 1
    fi
}

run_dev_mode() { 
    log_step "Running in DEV mode"
    
    # Source the IDP setup script to create users with fixed passwords
    log_info "Setting up HTPasswd identity provider..."
    # shellcheck source=setup-idp-openshift.sh
    if [[ "$SKIP_IDP_SETUP" == "true" ]]; then
        log_info "Skipping IDP setup, using existing users"
    else
        source "${SCRIPT_DIR}/setup-idp-openshift.sh" --fixed-passwords
    fi

    log_step "Running MaaS e2e Smoke Test"
    if ! "${SCRIPT_DIR}/prow_run_smoke_test.sh"; then
        log_error "Smoke test failed"
        exit 1
    fi
}


# ================================
# Main
# ================================

log_banner "MaaS E2E Test "
log_kv "Mode" "$MODE"

if [[ "$MODE" == "ci" ]]; then
    run_ci_mode
elif [[ "$MODE" == "dev" ]]; then
    run_dev_mode
fi
