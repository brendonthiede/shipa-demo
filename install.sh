#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export SHIPA_NAMESPACE=shipa-system
export API_NODEPORT="30443"

echo "Pulling current cluster metadata."
export STACK_INFO="$(kubectl get configmaps ddmi-metadata -n default -o jsonpath='{.data}')"
export CLOUD="$(echo "${STACK_INFO}" | jq -r '.cloud')"
export PROJECT="$(echo "${STACK_INFO}" | jq -r '.project')"
export STACK="$(echo "${STACK_INFO}" | jq -r '.stack')"
export STACK_URL="${STACK}.${PROJECT}.${CLOUD}.local-os"
export LIVE_URL="internal.${PROJECT}.${CLOUD}.local-os"
export STANDBY_URL="standby.${PROJECT}.${CLOUD}.local-os"

if [[ -z "${STACK}" ]]; then
  echo "[ERROR] Could not pull cluster metadata. Aborting."
  exit 1
fi

function installShipaChart() {
  if [[ "$(kubectl get ns ${SHIPA_NAMESPACE} -o jsonpath='{.metadata.name}' 2>/dev/null)" == "${SHIPA_NAMESPACE}" ]]; then
    echo "${SHIPA_NAMESPACE} namespace already exists. Skipping installation."
    return 1
  fi
  local -r _password="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9#@!' | fold -w 32 | head -n 1)"
  echo "Adding Shipa Helm repo"
  helm repo add shipa-helm https://artifactory.renhsc.com/artifactory/shipa-helm

  cat >"${DIR}/values.override.yaml" <<EOF
auth:
  adminUser: shipa@deltadentalmi.com
  adminPassword: ${_password}
shipaCluster:
  serviceType: ClusterIP
  istioServiceType: ClusterIP
service:
  nginx:
    serviceType: NodePort
shipaApi:
  cnames: ["${STACK_URL}", "${LIVE_URL}", "${STANDBY_URL}"]
mongodb-replicaset:
  installImage:
    repository: docker-virtual.artifactory.renhsc.com/k8s-gcr-io/mongodb-install
    name: docker-virtual.artifactory.renhsc.com/k8s-gcr-io/mongodb-install
  image:
    repository: docker-virtual.artifactory.renhsc.com/k8s-gcr-io/mongodb-install
    name: docker-virtual.artifactory.renhsc.com/k8s-gcr-io/mongodb-install
EOF

  echo "Installing Shipa Helm chart"
  helm install shipa shipa-helm/shipa --namespace ${SHIPA_NAMESPACE} --create-namespace --timeout=15m --values "${DIR}/values.override.yaml"
}

function setNodePort() {
  echo "Setting NodePort for shipa-secure to ${API_NODEPORT}"
  kubectl patch svc shipa-ingress-nginx -n shipa-system --patch "
spec:
  ports:
  - name: shipa-secure
    nodePort: ${API_NODEPORT}
    port: 8081
    protocol: TCP
    targetPort: 8081
"
}

function getShipaLoginInfo() {
  local -r _password="$(kubectl get secrets -n shipa-system shipa-api-init-secret -o jsonpath='{.data.password}' | base64 -d)"
  local -r _username="$(kubectl get secrets -n shipa-system shipa-api-init-secret -o jsonpath='{.data.username}' | base64 -d)"
  printf "Login credentials\nuser: %s\npassword: %s\n" "${_username}" "${_password}"
}

installShipaChart
setNodePort
getShipaLoginInfo

shipa target add ${STACK} --port 8443 -s
