#!/bin/bash

CLUSTER=$1 # Cluster name from clusters/<cluster-name>
ISSUER_URL=$2
CLIENT_ID=$3

if [[ -z $1 || -z $2 || -z $3 || $4 ]]; then
    echo "Script requires exactly three args: cluster, issuerUrl, clientId"
    exit 1
fi

# Use the cluster admin kubeconfig to extra the relevant OIDC details
export KUBECONFIG=clusters/$CLUSTER/kubeconfig

# NOTE: Assumes that there is only one cluster resource in target namespace
NAMESPACE=capi-self
CLUSTER_RELEASE_NAME=$(kubectl get cluster -n $NAMESPACE --no-headers | awk '{print $1}')

if [[ -z $CLUSTER_RELEASE_NAME ]]; then
    echo "Failed to determine cluster release name - no clusters found in namespace $NAMESPACE."
    exit 1
fi

K8S_HOST=$(kubectl get cluster -n $NAMESPACE $CLUSTER_RELEASE_NAME -o go-template='{{.spec.controlPlaneEndpoint.host}}')
K8S_PORT=$(kubectl get cluster -n $NAMESPACE $CLUSTER_RELEASE_NAME -o go-template='{{.spec.controlPlaneEndpoint.port}}')
CADATA=$(kubectl get secret -n $NAMESPACE $CLUSTER_RELEASE_NAME-ca -o go-template='{{index .data "tls.crt"}}')

cat << EOF > clusters/$CLUSTER/kubeconfig-oidc.yaml
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${CADATA}
      server: https://${K8S_HOST}:${K8S_PORT}
    name: $CLUSTER_RELEASE_NAME
users:
  - name: oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --grant-type=device-code  # or authcode for Authorization Code + PKCE
          - --oidc-issuer-url=$ISSUER_URL
          - --oidc-client-id=$CLIENT_ID
contexts:
- context:
    cluster: $CLUSTER_RELEASE_NAME
    user: oidc
  name: oidc@$CLUSTER_RELEASE_NAME
current-context: oidc@$CLUSTER_RELEASE_NAME
preferences: {}
EOF
