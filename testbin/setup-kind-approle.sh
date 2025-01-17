#!/usr/bin/env bash

set -o errexit

# Create registry container unless it already exists
reg_name='kind-registry'
reg_port='5000'
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run \
    -d --restart=always -p "${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

# Create a cluster with the local registry enabled in containerd
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.21.2
- role: worker
  image: kindest/node:v1.21.2
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
EOF

# Connect the registry to the cluster network (the network may already be connected)
docker network connect "kind" "${reg_name}" || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Build the image for the operator and push the image to our local registry
docker build . -t localhost:5000/vault-secrets-operator:test
docker push localhost:5000/vault-secrets-operator:test

kubectl create ns vault
kubectl create ns vault-secrets-operator

# Install Vault in the cluster and create a new secret engine for the operator
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault --namespace=vault --version=0.17.1 --set server.dev.enabled=true --set injector.enabled=false --set server.image.tag="1.8.4"

sleep 10s
kubectl wait pod/vault-0 --namespace=vault  --for=condition=Ready --timeout=180s
kubectl port-forward --namespace vault vault-0 8200 &
sleep 10s

vault login root
vault secrets enable -path=kvv2 -version=2 kv
cat <<EOF | vault policy write vault-secrets-operator -
path "kvv2/data/*" {
  capabilities = ["read"]
}
EOF

# Enable Vault AppRole auth method
vault auth enable approle

# Create new AppRole
vault write auth/approle/role/vault-secrets-operator token_policies=vault-secrets-operator

# Get AppRole ID and secret ID
VAULT_ROLE_ID=$(vault read auth/approle/role/vault-secrets-operator/role-id -format=json | jq -r .data.role_id)
VAULT_SECRET_ID=$(vault write -f auth/approle/role/vault-secrets-operator/secret-id -format=json | jq -r .data.secret_id)

cat <<EOF > ./vault-secrets-operator.env
VAULT_ROLE_ID=$VAULT_ROLE_ID
VAULT_SECRET_ID=$VAULT_SECRET_ID
EOF

kubectl create secret generic vault-secrets-operator \
  --namespace=vault-secrets-operator \
  --from-env-file=./vault-secrets-operator.env

cat <<EOF > ./values.yaml
vault:
  address: http://vault.vault.svc.cluster.local:8200
  authMethod: approle
image:
  repository: localhost:5000/vault-secrets-operator
  tag: test
environmentVars:
  - name: VAULT_ROLE_ID
    valueFrom:
      secretKeyRef:
        name: vault-secrets-operator
        key: VAULT_ROLE_ID
  - name: VAULT_SECRET_ID
    valueFrom:
      secretKeyRef:
        name: vault-secrets-operator
        key: VAULT_SECRET_ID
EOF

helm upgrade --install vault-secrets-operator ./charts/vault-secrets-operator --namespace=vault-secrets-operator -f ./values.yaml

vault kv put kvv2/helloworld foo=bar

cat <<EOF | kubectl apply -f -
apiVersion: ricoberger.de/v1alpha1
kind: VaultSecret
metadata:
  name: helloworld
spec:
  vaultRole: vault-secrets-operator
  path: kvv2/helloworld
  type: Opaque
EOF

kubectl wait pod --namespace=vault-secrets-operator -l app.kubernetes.io/instance=vault-secrets-operator --for=condition=Ready --timeout=180s
sleep 10s
kubectl get secret helloworld -o yaml
kubectl logs --namespace=vault-secrets-operator -l app.kubernetes.io/instance=vault-secrets-operator
