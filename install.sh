#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

ADMIN_PASSWORD="${1:-$(LC_ALL=C tr -dc '[:alnum:]' </dev/urandom | dd bs=4 count=8 2>/dev/null)}"
LICENSE_KEY="${2}"

function writeMessage() {
    echo >&2 -e "[${1}] $(date "+%Y-%m-%d %H:%M:%S") ${2}"
}

function exitError() {
    writeError "${1}"
    exit 1
}

function writeError() {
    writeMessage "ERROR" "${1}"
}

function writeInfo() {
    writeMessage "INFO" "${1}"
}

function isHelmReleaseDeployed() {
    local -r _release_name="${1}"
    local -r _namespace="${2}"
    if [[ "$(helm status ${_release_name} --namespace ${_namespace} --output json 2>/dev/null | jq --raw-output '.info.status' 2>/dev/null)" == "deployed" ]]; then
        echo "true"
    fi
}

function installChart() {
    local -r _release_name="${1}"
    local -r _chart="${2}"
    local -r _namespace="${3}"

    writeInfo "Installing Helm release ${_release_name} from ${_chart} in the ${_namespace} namespace."
    helm upgrade --install ${_release_name} ${_chart} --namespace ${_namespace} --create-namespace --timeout 15m --values "${DIR}/values.override.yaml" || exit 1
    writeInfo "Checking for a status of 'deployed'."
    for i in {1..180}; do
        [[ "$(isHelmReleaseDeployed ${_release_name} ${_namespace})" ]] && break || sleep 5
        printf "."
    done
    printf "\n"
    [[ "$(isHelmReleaseDeployed ${_release_name} ${_namespace})" ]] || exitError "Failed to install Helm release ${_release_name}"
}

function installMongoChart() {
    cat >"${DIR}/values.override.yaml" <<EOF
auth:
  rootPassword: $(generateRandomPassword)
EOF
    if [[ "$(isHelmReleaseDeployed mongodb mongodb)" ]]; then
        writeInfo "Helm release mongodb already exists."
        return 1
    else
        installChart mongodb ${MONGO_HELM_TGZ_URL} mongodb
    fi
}

function installShipaChart() {
    local -r _mongo_password="$(kubectl get secrets --namespace mongodb mongodb --output jsonpath='{.data.mongodb-root-password}' | base64 --decode)"
    local -r _mongo_port="$(kubectl get svc --namespace mongodb mongodb --output jsonpath='{.spec.ports[0].port}')"

    helm install shipa ${SHIPA_HELM_TGZ_URL} --namespace shipa-system --dry-run --set=auth.adminUser=abc@shipa.io --set=auth.adminPassword=abc123 >/tmp/shipa.yaml
    local -r _buildkit_frontend_source="${PRIVATE_REGISTRY_URL}/$(grep 'frontend-source:' /tmp/shipa.yaml | head -n1 | awk '{print $2}' | sed 's/"//g')"
    local -r _platforms_static_image="${PRIVATE_REGISTRY_URL}/$(grep 'shipasoftware/static:' /tmp/shipa.yaml | head -n1 | awk '{print $2}' | sed 's/"//g')"
    local -r _dashboard_image="${PRIVATE_REGISTRY_URL}/$(grep 'shipasoftware/dashboard:' /tmp/shipa.yaml | head -n1 | awk '{print $2}' | sed 's/"//g')"
    rm -f /tmp/shipa.yaml

    if [[ -z "${_buildkit_frontend_source}" || -z "${_platforms_static_image}" || -z "${_dashboard_image}" ]]; then
        exitError "Unable to determine configuration for buildkit frontend source, platform static, and/or dashboard"
    fi

    cat >"${DIR}/values.override.yaml" <<EOF
service:
  nginx:
    serviceType: NodePort
    apiNodePort: 32200
    secureApiNodePort: 32201
    etcdNodePort: 32202
    dockerRegistryNodePort: 32203
auth:
  adminUser: shipa@shipa.demo
  adminPassword: ${ADMIN_PASSWORD}
$([[ -n "${LICENSE_KEY}" ]] && echo "license: ${LICENSE_KEY}")
shipaApi:
  debug: true
  cnames: ["${STACK_URL}", "${LIVE_URL}", "${STANDBY_URL}"]
tags:
  defaultDB: false
externalMongodb:
  url: mongodb.mongodb.svc.cluster.local:${_mongo_port}
  auth:
    username: root
    password: ${_mongo_password}
  tls:
    enable: false
buildkit:
  frontendSource: ${_buildkit_frontend_source}
platforms:
  staticImage: ${_platforms_static_image}
dashboard:
  image: ${_dashboard_image}
EOF

    installChart shipa ${SHIPA_HELM_TGZ_URL} ${SHIPA_NAMESPACE}
}

function getShipaLoginInfo() {
    local -r _shipa_secret="$(kubectl get secrets --namespace ${SHIPA_NAMESPACE} shipa-api-init-secret --output jsonpath='{.data}')"
    local -r _username="$(echo "${_shipa_secret}" | jq --raw-output '.username' | base64 --decode)"
    local -r _password="$(echo "${_shipa_secret}" | jq --raw-output '.password' | base64 --decode)"
    printf "== Login credentials for Shipa CLI ==\nuser: %s\npassword: %s\n" "${_username}" "${_password}"
}

function setupShipaCli() {
    local -r _username="$(kubectl get secrets --namespace ${SHIPA_NAMESPACE} shipa-api-init-secret --output jsonpath='{.data.username}' | base64 --decode)"
    if [[ "$(shipa help 2>/dev/null | head -n1 | awk '{print $3}')" != "${SHIPA_CLI_VERSION}." ]]; then
        writeInfo "Installing Shipa CLI"
        curl -s https://storage.googleapis.com/shipa-client/install.sh | VERSION=${SHIPA_CLI_VERSION} bash
    fi
    writeInfo "Configuring Shipa CLI target named '${STACK}' at ${STACK_URL}:${API_EXTERNALPORT}"
    shipa target add ${STACK} ${STACK_URL} --port ${API_EXTERNALPORT} --set-current
    shipa login ${_username}
}

function createCustomIngress() {
    local -r _http_def="http:
      paths:
      - backend:
          serviceName: dashboard-web-1
          servicePort: 80
        path: /
        pathType: ImplementationSpecific"

    cat <<EOF | kubectl apply --namespace "${SHIPA_NAMESPACE}" -f -
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
    cert-manager.io/common-name: ${STACK_URL}
    nginx.ingress.kubernetes.io/backend-protocol: HTTP
  labels:
    app.kubernetes.io/name: openstack-configmaps
  name: shipa-dashboard
  namespace: ${SHIPA_SYSTEM}
spec:
  rules:
  - host: ${STACK_URL}
    ${_http_def}
  - host: ${LIVE_URL}
    ${_http_def}
  - host: ${STANDBY_URL}
    ${_http_def}
  tls:
  - hosts:
    - ${STACK_URL}
    - ${LIVE_URL}
    - ${STANDBY_URL}
    secretName: dashboard-ingress-tls
EOF
}

export SHIPA_REPO_NAME="shipa-helm-rc"
export SHIPA_VERSION="1.3.0-rc-12"
export SHIPA_CLI_VERSION="1.3.0-rc-7"

export MONGO_VERSION="10.12.6"
export MONGO_REPO_NAME="bitnami-helm"

export PRIVATE_REGISTRY_URL="docker-virtual.artifactory.renhsc.com"
export ARTIFACTORY_URL="https://artifactory.renhsc.com/artifactory"
export MONGO_HELM_TGZ_URL="${ARTIFACTORY_URL}/${MONGO_REPO_NAME}/mongodb-${MONGO_VERSION}.tgz"
export SHIPA_HELM_TGZ_URL="${ARTIFACTORY_URL}/${SHIPA_REPO_NAME}/shipa-${SHIPA_VERSION}.tgz"

export SHIPA_NAMESPACE="shipa-system"
export API_EXTERNALPORT="8081" # Managed through HA Proxy configuration

export DIR="${DIR:-$(pwd)}"

writeInfo "Pulling current cluster metadata."
export STACK_INFO="$(kubectl get configmaps ddmi-metadata --namespace default --output jsonpath='{.data}')"
export CLOUD="$(echo "${STACK_INFO}" | jq --raw-output '.cloud')"
export PROJECT="$(echo "${STACK_INFO}" | jq --raw-output '.project')"
export STACK="$(echo "${STACK_INFO}" | jq --raw-output '.stack')"
export STACK_URL="${STACK}.${PROJECT}.${CLOUD}.local-os"
export LIVE_URL="internal.${PROJECT}.${CLOUD}.local-os"
export STANDBY_URL="standby.${PROJECT}.${CLOUD}.local-os"

if [[ -z "${STACK}" ]]; then
    exitError "Could not pull cluster metadata. Aborting."
fi

installMongoChart
installShipaChart
getShipaLoginInfo
setupShipaCli
createCustomIngress
