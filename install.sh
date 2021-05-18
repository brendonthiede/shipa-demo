#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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

function generateRandomPassword() {
    LC_ALL=C tr -dc '[:alnum:]' </dev/urandom | dd bs=4 count=8 2>/dev/null
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

    if [[ "$(isHelmReleaseDeployed ${_release_name} ${_namespace})" ]]; then
        writeInfo "Helm release ${_release_name} already exists."
        return 1
    else
        writeInfo "Installing Helm release ${_release_name} from ${_chart} in the ${_namespace} namespace."
        helm install ${_release_name} ${_chart} --namespace ${_namespace} --create-namespace --timeout 15m --values "${DIR}/values.override.yaml" || exit 1
        writeInfo "Checking for a status of 'deployed'."
        for i in {1..180}; do
            [[ "$(isHelmReleaseDeployed ${_release_name} ${_namespace})" ]] && break || sleep 5
            printf "."
        done
        printf "\n"
        [[ "$(isHelmReleaseDeployed ${_release_name} ${_namespace})" ]] || exitError "Failed to install Helm release ${_release_name}"
    fi
}

function installMongoChart() {
    cat >"${DIR}/values.override.yaml" <<EOF
auth:
  rootPassword: $(generateRandomPassword)
EOF
    installChart mongodb ${ARTIFACTORY_URL}/${MONGO_REPO_NAME}/mongodb-${MONGO_VERSION}.tgz mongodb
}

function installShipaChart() {
    local -r _mongo_password="$(kubectl get secrets --namespace mongodb mongodb --output jsonpath='{.data.mongodb-root-password}' | base64 --decode)"
    local -r _mongo_port="$(kubectl get svc --namespace mongodb mongodb --output jsonpath='{.spec.ports[0].port}')"

    cat >"${DIR}/values.override.yaml" <<EOF
service:
  nginx:
    serviceType: NodePort
    apiNodePort: 32200
    secureApiNodePort: 32201
    etcdNodePort: 32202
    dockerRegistryNodePort: 32203
auth:
  adminUser: shipa@deltadentalmi.com
  adminPassword: $(generateRandomPassword)
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
  frontendSource: ${BUILDKIT_FRONTEND_SOURCE}
platforms:
  staticImage: ${PLATFORMS_STATIC_IMAGE}
dashboard:
  image: ${DASHBOARD_IMAGE}
EOF

    installChart shipa ${ARTIFACTORY_URL}/${SHIPA_REPO_NAME}/shipa-${SHIPA_VERSION}.tgz ${SHIPA_NAMESPACE}
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

export DIR="${DIR:-$(pwd)}"
export SHIPA_REPO_NAME="shipa-helm-rc"
export SHIPA_VERSION="1.3.0-rc-12"
export SHIPA_CLI_VERSION="1.3.0-rc-7"
export PRIVATE_REGISTRY_URL="docker-virtual.artifactory.renhsc.com"
export BUILDKIT_FRONTEND_SOURCE=${PRIVATE_REGISTRY_URL}/docker/dockerfile
export PLATFORMS_STATIC_IMAGE=${PRIVATE_REGISTRY_URL}/shipasoftware/static:v1.2
export DASHBOARD_IMAGE=${PRIVATE_REGISTRY_URL}/shipasoftware/dashboard:v1.3.0-rc-12-2
export MONGO_VERSION="10.12.6"
export MONGO_REPO_NAME="bitnami-helm"
export ARTIFACTORY_URL="https://artifactory.renhsc.com/artifactory"
export SHIPA_NAMESPACE="shipa-system"
export API_EXTERNALPORT="8081"

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
