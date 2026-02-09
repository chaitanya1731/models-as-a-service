#!/bin/bash

# =============================================================================
# MaaS Platform End-to-End Testing Script
# =============================================================================
#
# This script automates the complete deployment and validation of the MaaS 
# platform on OpenShift with multi-user testing capabilities.
#
# WHAT IT DOES:
#   1. Deploy MaaS platform on OpenShift
#   2. Deploy simulator model for testing
#   3. Validate deployment functionality
#   4. Create test users with different permission levels:
#      - Admin user (cluster-admin role)
#      - Edit user (edit role) 
#      - View user (view role)
#   5. Run token metadata verification (as admin user)
#   6. Run smoke tests for each user
# 
# USAGE:
#   ./test/e2e/scripts/prow_run_smoke_test.sh
#
# ENVIRONMENT VARIABLES:
#   SKIP_VALIDATION - Skip deployment validation (default: false)
#   SKIP_SMOKE      - Skip smoke tests (default: false)
#   SKIP_TOKEN_VERIFICATION - Skip token metadata verification (default: false)
#   SKIP_AUTH_CHECK - Skip Authorino auth readiness check (default: true, temporary workaround)
#   MAAS_API_IMAGE - Custom image for MaaS API (e.g., quay.io/opendatahub/maas-api:pr-232)
#   INSECURE_HTTP  - Deploy without TLS and use HTTP for tests (default: false)
#                    Affects both deploy-openshift.sh and smoke.sh
# =============================================================================

set -euo pipefail

find_project_root() {
  local start_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local marker="${2:-.git}"
  local dir="$start_dir"

  while [[ "$dir" != "/" && ! -e "$dir/$marker" ]]; do
    dir="$(dirname "$dir")"
  done

  if [[ -e "$dir/$marker" ]]; then
    printf '%s\n' "$dir"
  else
    echo "Error: couldn't find '$marker' in any parent of '$start_dir'" >&2
    return 1
  fi
}

# Configuration
PROJECT_ROOT="$(find_project_root)"

# Source helper functions
source "$PROJECT_ROOT/scripts/deployment-helpers.sh"

# Options (can be set as environment variables)
SKIP_VALIDATION=${SKIP_VALIDATION:-false}
SKIP_SMOKE=${SKIP_SMOKE:-false}
SKIP_TOKEN_VERIFICATION=${SKIP_TOKEN_VERIFICATION:-false}
SKIP_AUTH_CHECK=${SKIP_AUTH_CHECK:-true}  # TODO: Set to false once operator TLS fix lands
INSECURE_HTTP=${INSECURE_HTTP:-false}

print_header() {
    echo ""
    echo "----------------------------------------"
    echo "$1"
    echo "----------------------------------------"
    echo ""
}

check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Get current user (also checks if logged in)
    local current_user
    if ! current_user=$(oc whoami 2>/dev/null); then
        echo "❌ ERROR: Not logged into OpenShift. Please run 'oc login' first"
        exit 1
    fi
    
    # Combined check: admin privileges + OpenShift cluster
    if ! oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
        echo "❌ ERROR: User '$current_user' does not have admin privileges"
        echo "   This script requires cluster-admin privileges to deploy and manage resources"
        echo "   Please login as an admin user with 'oc login' or contact your cluster administrator"
        exit 1
    elif ! kubectl get --raw /apis/config.openshift.io/v1/clusterversions >/dev/null 2>&1; then
        echo "❌ ERROR: This script is designed for OpenShift clusters only"
        exit 1
    fi
    
    echo "✅ Prerequisites met - Currently logged in as: $current_user on OpenShift"
}

deploy_maas_platform() {
    echo "Deploying MaaS platform on OpenShift..."
    if ! "$PROJECT_ROOT/scripts/deploy-rhoai-stable.sh" --operator-type odh --operator-catalog quay.io/opendatahub/opendatahub-operator-catalog:latest --channel fast; then
        echo "❌ ERROR: MaaS platform deployment failed"
        exit 1
    fi
    # Wait for DataScienceCluster's KServe and ModelsAsService to be ready
    if ! wait_datasciencecluster_ready "default-dsc" 600; then
        echo "❌ ERROR: DataScienceCluster components did not become ready"
        exit 1
    fi
    
    # Wait for Authorino to be ready and auth service cluster to be healthy
    # TODO(https://issues.redhat.com/browse/RHOAIENG-48760): Remove SKIP_AUTH_CHECK
    # once the operator creates the gateway→Authorino TLS EnvoyFilter at Gateway/AuthPolicy creation
    # time, not at first LLMInferenceService creation. Currently there's a chicken-egg problem where
    # auth checks fail before any model is deployed because the TLS config doesn't exist yet.
    if [[ "${SKIP_AUTH_CHECK:-false}" == "true" ]]; then
        echo "⚠️  WARNING: Skipping Authorino readiness check (SKIP_AUTH_CHECK=true)"
        echo "   This is a temporary workaround for the gateway→Authorino TLS chicken-egg problem"
    else
        echo "Waiting for Authorino and auth service to be ready..."
        if ! wait_authorino_ready 600; then
            echo "⚠️  WARNING: Authorino readiness check had issues, continuing anyway"
        fi
    fi
    
    echo "✅ MaaS platform deployment completed"
}

deploy_models() {
    echo "Deploying simulator Model"
    # Create llm namespace if it does not exist
    if ! kubectl get namespace llm >/dev/null 2>&1; then
        echo "Creating 'llm' namespace..."
        if ! kubectl create namespace llm; then
            echo "❌ ERROR: Failed to create 'llm' namespace"
            exit 1
        fi
    else
        echo "'llm' namespace already exists"
    fi
    if ! (cd "$PROJECT_ROOT" && kustomize build docs/samples/models/simulator/ | kubectl apply -f -); then
        echo "❌ ERROR: Failed to deploy simulator model"
        exit 1
    fi
    echo "✅ Simulator model deployed"
    
    echo "Waiting for model to be ready..."
    if ! oc wait llminferenceservice/facebook-opt-125m-simulated -n llm --for=condition=Ready --timeout=300s; then
        echo "❌ ERROR: Timed out waiting for model to be ready"
        echo "=== LLMInferenceService YAML dump ==="
        oc get llminferenceservice/facebook-opt-125m-simulated -n llm -o yaml || true
        echo "=== Events in llm namespace ==="
        oc get events -n llm --sort-by='.lastTimestamp' || true
        exit 1
    fi
    echo "✅ Simulator Model deployed"
}

validate_deployment() {
    echo "Deployment Validation"
    if [ "$SKIP_VALIDATION" = false ]; then
        if ! "$PROJECT_ROOT/scripts/validate-deployment.sh"; then
            echo "⚠️  First validation attempt failed, waiting 60 seconds and retrying..."
            sleep 60
            if ! "$PROJECT_ROOT/scripts/validate-deployment.sh"; then
                echo "❌ ERROR: Deployment validation failed after retry"
                exit 1
            fi
        fi
        echo "✅ Deployment validation completed"
    else
        echo "⏭️  Skipping validation"
    fi
}

setup_vars_for_tests() {
    echo "-- Setting up variables for tests --"
    K8S_CLUSTER_URL=$(oc whoami --show-server)
    export K8S_CLUSTER_URL
    if [ -z "$K8S_CLUSTER_URL" ]; then
        echo "❌ ERROR: Failed to retrieve Kubernetes cluster URL. Please check if you are logged in to the cluster."
        exit 1
    fi
    echo "K8S_CLUSTER_URL: ${K8S_CLUSTER_URL}"

    # Export INSECURE_HTTP for smoke.sh (it handles MAAS_API_BASE_URL detection)
    # HTTPS is the default for MaaS.
    # HTTP is used only when INSECURE_HTTP=true (opt-out mode).
    # This aligns with deploy-openshift.sh which also respects INSECURE_HTTP
    export INSECURE_HTTP
    if [ "$INSECURE_HTTP" = "true" ]; then
        echo "⚠️  INSECURE_HTTP=true - will use HTTP for tests"
    fi
    # Detect MAAS_API_BASE_URL while logged in as admin (non-admin users can't read cluster ingress)
    export CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    if [ -z "$CLUSTER_DOMAIN" ]; then
        echo "❌ ERROR: Failed to detect cluster ingress domain (ingresses.config.openshift.io/cluster)"
        exit 1
    fi
    export HOST="maas.${CLUSTER_DOMAIN}"

    if [ "$INSECURE_HTTP" = "true" ]; then
        export MAAS_API_BASE_URL="http://${HOST}/maas-api"
    else
        export MAAS_API_BASE_URL="https://${HOST}/maas-api"
    fi

    echo "HOST: ${HOST}"
    echo "MAAS_API_BASE_URL: ${MAAS_API_BASE_URL}"
    echo "CLUSTER_DOMAIN: ${CLUSTER_DOMAIN}"
    echo "✅ Variables for tests setup completed"
}

run_smoke_tests() {
    echo "-- Smoke Testing --"
    
    if [ "$SKIP_SMOKE" = false ]; then
        if ! (cd "$PROJECT_ROOT" && bash test/e2e/smoke.sh); then
            echo "❌ ERROR: Smoke tests failed"
            exit 1
        else
            echo "✅ Smoke tests completed successfully"
        fi
    else
        echo "⏭️  Skipping smoke tests"
    fi
}

run_token_verification() {
    echo "-- Token Metadata Verification --"
    
    if [ "$SKIP_TOKEN_VERIFICATION" = false ]; then
        if ! (cd "$PROJECT_ROOT" && bash scripts/verify-tokens-metadata-logic.sh); then
            echo "❌ ERROR: Token metadata verification failed"
            exit 1
        else
            echo "✅ Token metadata verification completed successfully"
        fi
    else
        echo "Skipping token metadata verification..."
    fi
}

smoke_test_bundle() {
    echo "-- Running Validation Tests for MaaS --"
    # Skip validation and token verification for non-admin users as 
    # currently validate-deployment.sh and verify-tokens-metadata-logic.sh are only run for admin users
    # TODO: Implement Validation/Token Verification for non-admin users in 
    # ./scripts/validate-deployment.sh and ./scripts/verify-tokens-metadata-logic.sh
    # TODO: Consolidate all validations in a single test suite.
    # if ! oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
    #     echo "⏭️  Skipping validation and token verification for non-admin users"
    # else
    #     validate_deployment
    #     echo "waiting for rate limit to reset..."
    #     sleep 120       # Wait for the rate limit to reset (120 seconds is the default rate limit window)
    # fi
    validate_deployment
    echo "waiting for rate limit to reset..."
    sleep 120       # Wait for the rate limit to reset (120 seconds is the default rate limit window)
    run_token_verification
    run_smoke_tests
    echo "✅ MaaS Validation Successful"
}

get_password_for_user() {
    local username="$1"
    echo "$USERS" | tr ',' '\n' | grep "^${username}:" | cut -d: -f2-
}

# Login as user and run smoke_test_bundle. Uses K8S_CLUSTER_URL from setup_vars_for_tests.
run_smoke_bundle_as_user() {
    local username="$1"
    local password
    password="$(get_password_for_user "$username")"
    if [ -z "$password" ]; then
        echo "❌ ERROR: No password found for user '$username' in \$USERS"
        return 1
    fi
    echo "Logging in as $username and running smoke test bundle..."
    if ! oc login "$K8S_CLUSTER_URL" -u "$username" -p "$password" --insecure-skip-tls-verify >/dev/null 2>&1; then
        echo "❌ ERROR: Failed to login as $username"
        return 1
    fi
    smoke_test_bundle
}

# Main execution
print_header "Deploying Maas on OpenShift"
check_prerequisites
deploy_maas_platform

print_header "Deploying Models"  
deploy_models

print_header "Setting up variables for tests"
setup_vars_for_tests

# When USERS_TO_TEST is set (e.g. by maas-e2e-test-runner.sh), run smoke bundle for each user.
# When not set (script run directly), run smoke bundle once for the already logged-in user.
print_header "Running MaaS test bundle"
if [ -n "${USERS_TO_TEST:-}" ]; then
    if [ -z "${USERS:-}" ]; then
        echo "❌ ERROR: USERS not set. Please setup IDP users using maas-e2e-test-runner.sh --mode dev"
        exit 1
    fi
    print_header "Testing users: $USERS_TO_TEST"
    for username in $USERS_TO_TEST; do
        print_header "Testing user: $username"
        run_smoke_bundle_as_user "$username"
    done
else
    echo "Running MaaS test bundle for user: $(oc whoami)"
    smoke_test_bundle
fi

echo "🎉 MaaS Deployment and Smoke Tests completed successfully!"