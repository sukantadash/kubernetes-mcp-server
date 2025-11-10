
#Deploy the Keycloak instance and realm configuration
mcp_server_secret="YOUR_MCP_SERVER_SECRET_HERE"  #generated using uuidgen
CLUSTER_NAME="YOUR_CLUSTER_NAME"



#Test the setup
#Testing Token Exchange
#First, set some basic information including the RHBK host, username and password


RHBK_HOST=https://keycloak-admin.apps.${CLUSTER_NAME}

RHBK_REALM=openshift
RHBK_USERNAME=testdeveloper
RHBK_PASSWORD=dummy
MCP_CLIENT_ID=mcp-client

RHBK_TOKEN=$(curl -s -X POST $RHBK_HOST/realms/$RHBK_REALM/protocol/openid-connect/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d scope=mcp-server \
    -d username=$RHBK_USERNAME \
    -d password=$RHBK_PASSWORD \
    -d grant_type=password \
    -d client_id=$MCP_CLIENT_ID | jq -r '.access_token')

echo "RHBK_TOKEN: $RHBK_TOKEN"
#Decode the returned token

jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$RHBK_TOKEN"

#Taking the role of the MCP Server, set several variables related to the mcp-server Client that is used to authenticate against RHBK

MCP_SERVER_ID=mcp-server
MCP_SERVER_SECRET=${mcp_server_secret}

#Perform the token exchange by authenticating using the mcp-server Client, while requesting the openshift audience and the mcp:openshift scope using the RHBK_TOKEN retrieved previously:


K8S_TOKEN=$(curl -s $RHBK_HOST/realms/$RHBK_REALM/protocol/openid-connect/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id=$MCP_SERVER_ID \
    -d subject_token="$RHBK_TOKEN" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d audience=openshift \
    -d client_secret=$MCP_SERVER_SECRET \
    -d requested_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d scope=mcp:openshift | jq -r '.access_token')
echo "K8S_TOKEN: $K8S_TOKEN"
#Now, decode the returned JWT:

jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$K8S_TOKEN"

#Notice how it has the openshift audience which is needed to make requests to OpenShift

#Finally invoke OpenShift by first setting details related to the openshift cluster

OPENSHIFT_API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

#Retrieve information about the authenticated user

curl -k $OPENSHIFT_API_SERVER/apis/authentication.k8s.io/v1/selfsubjectreviews \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $K8S_TOKEN" \
    -X POST -d '{"kind":"SelfSubjectReview","apiVersion":"authentication.k8s.io/v1","metadata":{"creationTimestamp":null},"status":{"userInfo":{}}}'


echo "Testing llama-stack namespace"

curl -k -H "Authorization: Bearer ${K8S_TOKEN}" \
     "${OPENSHIFT_API_SERVER}/api/v1/namespaces/llama-stack/pods"

echo "Testing testdev2 namespace"

curl -k -H "Authorization: Bearer ${K8S_TOKEN}" \
     "${OPENSHIFT_API_SERVER}/api/v1/namespaces/testdev2/pods"
