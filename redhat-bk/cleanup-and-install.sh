#!/bin/bash
set -e

# Configuration
# Auto-detect cluster name from infrastructure if not provided
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' 2>/dev/null | sed 's|https://api\.||' | sed 's|:6443||' || echo "")
    if [ -z "$CLUSTER_NAME" ]; then
        # Fallback: try to get from ingress domain
        CLUSTER_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null || echo "")
    fi
    if [ -z "$CLUSTER_NAME" ]; then
        echo "❌ Error: Could not auto-detect cluster name. Please set CLUSTER_NAME environment variable."
        exit 1
    fi
fi
NAMESPACE="redhat-keycloak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Keycloak Cleanup and Install Script"
echo "=========================================="
echo ""
echo "📋 Cluster Name: ${CLUSTER_NAME}"
echo ""

# Function to cleanup resources
cleanup() {
    echo "🧹 Cleaning up existing resources..."
    
    # Delete realm imports
    echo "  - Deleting KeycloakRealmImport resources..."
    oc delete keycloakrealmimport --all -n ${NAMESPACE} 2>/dev/null || true
    
    # Delete Keycloak instance
    echo "  - Deleting Keycloak instance..."
    oc delete keycloak --all -n ${NAMESPACE} 2>/dev/null || true
    
    # Delete PostgreSQL
    echo "  - Deleting PostgreSQL..."
    oc delete postgresql --all -n ${NAMESPACE} 2>/dev/null || true
    oc delete secret postgresql-credentials -n ${NAMESPACE} 2>/dev/null || true
    
    # Remove Keycloak from OAuth config (patch instead of delete)
    echo "  - Removing Keycloak identity provider from OAuth configuration..."
    # Get current OAuth config and remove keycloak identity provider
    oc get oauth cluster -o json 2>/dev/null | \
        jq 'del(.spec.identityProviders[]? | select(.name == "keycloak"))' | \
        oc apply -f - 2>/dev/null || true
    
    # Delete secrets
    echo "  - Deleting secrets..."
    oc delete secret keycloak-client-openshift-secret -n openshift-config 2>/dev/null || true
    
    # Note: We keep the CA bundle configmap as it may be needed for other purposes
    # and can be reused if it exists
    
    # Uninstall operator (do this last so operator can clean up finalizers)
    echo "  - Uninstalling Keycloak operator..."
    # Delete subscription first
    oc delete subscription rhbk-operator -n ${NAMESPACE} 2>/dev/null || true
    # Wait a bit for operator to process deletion
    sleep 5
    # Delete CSV (ClusterServiceVersion) if it exists
    CSV_NAME=$(oc get csv -n ${NAMESPACE} -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Build of Keycloak")].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CSV_NAME" ]; then
        echo "  - Deleting ClusterServiceVersion: ${CSV_NAME}"
        oc delete csv ${CSV_NAME} -n ${NAMESPACE} 2>/dev/null || true
    fi
    # Delete operatorgroup
    oc delete operatorgroup keycloak-operator-group -n ${NAMESPACE} 2>/dev/null || true
    # Wait for operator to be removed
    echo "  - Waiting for operator to be removed..."
    sleep 10
    
    # Wait for resources to be deleted
    echo "  - Waiting for resources to be deleted..."
    sleep 5
    
    # Delete namespace/project (this will delete all remaining resources)
    echo "  - Deleting namespace/project: ${NAMESPACE}..."
    oc delete project ${NAMESPACE} 2>/dev/null || true
    # Wait for namespace to be deleted
    echo "  - Waiting for namespace to be deleted..."
    MAX_WAIT=60
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if ! oc get project ${NAMESPACE} &>/dev/null; then
            echo "  - Namespace deleted"
            break
        fi
        echo "  - Waiting for namespace deletion... (${ELAPSED}s/${MAX_WAIT}s)"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    
    echo "✅ Cleanup completed"
    echo ""
}

# Function to install resources
install() {
    echo "🚀 Installing Keycloak..."
    echo ""
    
    # Create namespace if it doesn't exist
    echo "📦 Creating namespace if needed..."
    oc apply -f ${SCRIPT_DIR}/operator/base/namespace.yaml
    echo "  - Namespace ${NAMESPACE} ready"
    echo ""
    
    # Generate secrets
    echo "📝 Generating secrets..."
    postgres_password=$(uuidgen)
    mcp_server_secret=$(uuidgen)
    openshift_secret=$(uuidgen)
    echo "  - PostgreSQL Password: ${postgres_password}"
    echo "  - MCP Server Secret: ${mcp_server_secret}"
    echo "  - OpenShift Client Secret: ${openshift_secret}"
    echo ""
    
    # Deploy operator
    echo "📦 Deploying Keycloak operator..."
    oc apply -k ${SCRIPT_DIR}/operator/overlays/stable/
    echo "  - Waiting for operator to be ready..."
    MAX_WAIT=300
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if oc get deployment rhbk-operator -n ${NAMESPACE} &>/dev/null; then
            if oc wait --for=condition=available --timeout=10s deployment/rhbk-operator -n ${NAMESPACE} &>/dev/null; then
                echo "  - Operator is ready"
                break
            fi
        fi
        echo "  - Waiting for operator... (${ELAPSED}s/${MAX_WAIT}s)"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    echo ""
    
    # Create OpenShift secret
    echo "🔐 Creating OpenShift client secret..."
    oc create secret generic keycloak-client-openshift-secret \
        --from-literal=clientSecret="${openshift_secret}" \
        -n openshift-config --dry-run=client -o yaml | oc apply -f -
    echo ""
    
    # Create CA bundle configmap if it doesn't exist
    echo "🔐 Creating Keycloak CA bundle configmap..."
    if ! oc get configmap keycloak-ca-bundle -n openshift-config &>/dev/null; then
        oc get configmap -n openshift-config-managed default-ingress-cert \
            -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/keycloak-ca.crt 2>/dev/null || true
        if [ -s /tmp/keycloak-ca.crt ]; then
            oc create configmap keycloak-ca-bundle \
                --from-file=ca.crt=/tmp/keycloak-ca.crt \
                -n openshift-config --dry-run=client -o yaml | oc apply -f -
            rm -f /tmp/keycloak-ca.crt
            echo "  - CA bundle created"
        else
            echo "  - ⚠️  Warning: Could not create CA bundle. You may need to create it manually."
        fi
    else
        echo "  - CA bundle already exists"
    fi
    echo ""
    
    # Update YAML files with secrets and cluster name
    echo "📝 Updating configuration files..."
    cd ${SCRIPT_DIR}/cluster
    
    # Backup original files
    cp 01_postgresql.yaml 01_postgresql.yaml.bak 2>/dev/null || true
    cp 02_keycloak.yaml 02_keycloak.yaml.bak 2>/dev/null || true
    cp 04_realm.yaml 04_realm.yaml.bak 2>/dev/null || true
    cp oauth-config.yaml oauth-config.yaml.bak 2>/dev/null || true
    
    # Replace PostgreSQL password
    sed -i '' "s|CHANGE_ME_IN_PRODUCTION|${postgres_password}|g" 01_postgresql.yaml
    
    # Replace secrets
    sed -i '' "s|secret: \"YOUR_MCP_SERVER_SECRET_HERE\"|secret: \"${mcp_server_secret}\"|g" 04_realm.yaml
    sed -i '' "s|secret: \"YOUR_OPENSHIFT_CLIENT_SECRET_HERE\"|secret: \"${openshift_secret}\"|g" 04_realm.yaml
    
    # Replace cluster name
    sed -i '' "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" 02_keycloak.yaml
    sed -i '' "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" 04_realm.yaml
    sed -i '' "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" oauth-config.yaml
    
    echo "  - Updated 01_postgresql.yaml"
    echo "  - Updated 02_keycloak.yaml"
    echo "  - Updated 04_realm.yaml"
    echo "  - Updated oauth-config.yaml"
    
    # Update test script with secrets and cluster name
    cd ${SCRIPT_DIR}
    if [ -f test-script.sh ]; then
        cp test-script.sh test-script.sh.bak 2>/dev/null || true
        sed -i '' "s|YOUR_MCP_SERVER_SECRET_HERE|${mcp_server_secret}|g" test-script.sh
        sed -i '' "s|YOUR_CLUSTER_NAME|${CLUSTER_NAME}|g" test-script.sh
        echo "  - Updated test-script.sh"
    fi
    cd ${SCRIPT_DIR}/cluster
    echo ""
 
    # Deploy Keycloak and realm using kustomize
    echo "🏗️  Deploying Keycloak instance and realm..."
    oc apply -k ${SCRIPT_DIR}/cluster
    
    # Patch OAuth config (handle update properly)
    echo "🔐 Applying OAuth configuration..."
    if oc get oauth cluster &>/dev/null; then
        # OAuth exists, merge the Keycloak identity provider
        CURRENT_OAUTH=$(oc get oauth cluster -o json)
        # Convert YAML to JSON and extract the Keycloak provider (use create to avoid merging with existing)
        KEYCLOAK_PROVIDER=$(oc create --dry-run=client -f ${SCRIPT_DIR}/cluster/oauth-config.yaml -o json 2>/dev/null | jq '.spec.identityProviders[0]')
        # Validate that we got a valid provider
        if [ -z "$KEYCLOAK_PROVIDER" ] || [ "$KEYCLOAK_PROVIDER" = "null" ]; then
            echo "  ❌ Error: Failed to extract Keycloak provider from YAML"
            exit 1
        fi
        # Check if keycloak provider already exists
        if echo "$CURRENT_OAUTH" | jq -e '.spec.identityProviders[]? | select(.name == "keycloak")' &>/dev/null; then
            echo "  - Keycloak identity provider already exists, updating..."
            # Update existing provider
            echo "$CURRENT_OAUTH" | jq --argjson provider "$KEYCLOAK_PROVIDER" '(.spec.identityProviders[] | select(.name == "keycloak")) = $provider' | oc apply -f -
        else
            # Add the keycloak provider
            echo "$CURRENT_OAUTH" | jq --argjson provider "$KEYCLOAK_PROVIDER" '.spec.identityProviders += [$provider]' | oc apply -f -
            echo "  - Added Keycloak identity provider to OAuth config"
        fi
    else
        # OAuth doesn't exist, create it
        oc apply -f ${SCRIPT_DIR}/cluster/oauth-config.yaml
        echo "  - Created OAuth configuration"
    fi
    echo ""
    
    # Wait for Keycloak to be ready
    echo "⏳ Waiting for Keycloak to be ready..."
    MAX_WAIT=300
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if oc get keycloak -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
            echo "✅ Keycloak is ready"
            break
        fi
        echo "  - Waiting... (${ELAPSED}s/${MAX_WAIT}s)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    
    # Wait for realm import
    echo "⏳ Waiting for realm import to complete..."
    sleep 10
    MAX_WAIT=180
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        STATUS=$(oc get keycloakrealmimport -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "False")
        if [ "$STATUS" = "True" ]; then
            echo "✅ Realm import completed"
            break
        fi
        HAS_ERRORS=$(oc get keycloakrealmimport -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type=="HasErrors")].status}' 2>/dev/null || echo "False")
        if [ "$HAS_ERRORS" = "True" ]; then
            echo "❌ Realm import has errors. Check logs:"
            oc get keycloakrealmimport -n ${NAMESPACE} -o yaml | grep -A 5 "message:"
            exit 1
        fi
        echo "  - Waiting... (${ELAPSED}s/${MAX_WAIT}s)"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    
    echo ""
    echo "✅ Installation completed"
    echo ""
    
    # Restart OAuth pods to pick up authentication config changes
    echo "🔄 Restarting OAuth pods to apply authentication configuration..."
    oc delete pods -n openshift-authentication -l app=oauth-openshift 2>/dev/null || true
    sleep 5
    echo "  - OAuth pods restarted"
    echo ""
    
    # Display Keycloak URL
    KEYCLOAK_URL=$(oc get keycloak -n ${NAMESPACE} -o jsonpath='{.items[0].spec.instances[0].hostname}' 2>/dev/null || echo "")
    if [ -z "$KEYCLOAK_URL" ]; then
        KEYCLOAK_URL=$(oc get route -n ${NAMESPACE} -l app=keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    fi
    if [ -z "$KEYCLOAK_URL" ]; then
        KEYCLOAK_URL="https://keycloak-admin.apps.${CLUSTER_NAME}"
    else
        KEYCLOAK_URL="https://${KEYCLOAK_URL}"
    fi
    echo "📋 Keycloak URL: ${KEYCLOAK_URL}"
    echo "📋 Realm: openshift"
    echo "📋 Test User: testdeveloper / dummy"
    echo ""
    echo "ℹ️  Note: It may take a few minutes for OAuth pods to restart and authentication to be fully available."
    echo ""
}

# Main execution
main() {
    if [ "$1" = "cleanup-only" ]; then
        cleanup
    elif [ "$1" = "install-only" ]; then
        install
    else
        cleanup
        install
    fi
}

# Run main function
main "$@"

