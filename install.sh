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

function copyRegistryCredentials() {
    local -r _target_namespace="${1}"
    local -r _secret_name="regcred"
    local -r _source_namespace="default"
    cat <<EOF | kubectl apply --namespace "${_target_namespace}" -f -
apiVersion: v1
data:
  .dockerconfigjson: $(kubectl get secrets --namespace ${_source_namespace} regcred --output 'jsonpath={.data.\.dockerconfigjson}')
kind: Secret
metadata:
  name: ${_secret_name}
  namespace: ${_target_namespace}
type: kubernetes.io/dockerconfigjson
EOF
}

function initializeNamespace() {
    local -r _target_namespace="${1}"
    kubectl create ns "${_target_namespace}" --dry-run=client --output yaml | kubectl apply -f -
    copyRegistryCredentials "${_target_namespace}"
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
    if [[ "$(shipa help 2>/dev/null | head -n1 | awk '{print $3}')" != "${SHIPA_CLI_VERSION}." ]]; then
        writeInfo "Installing Shipa CLI"
        curl -s https://storage.googleapis.com/shipa-client/install.sh | VERSION=${SHIPA_CLI_VERSION} bash
    fi
    writeInfo "Configuring Shipa CLI target named '${STACK}' at ${STACK_URL}:${API_EXTERNALPORT}"
    shipa target add ${STACK} ${STACK_URL} --port ${API_EXTERNALPORT} --set-current
    shipa login
}

function redeployDashboardFromArtifactory() {
    for _version in $(shipa app deploy list --app dashboard | grep '| \*' | awk '{print $4}' | awk -F ':' '{print $3}'); do
        shipa app deactivate --app dashboard --version ${_version/v/}
    done

    writeInfo "Credentials to use to connect to private image registry:"
    kubectl get secrets --namespace ${SHIPA_NAMESPACE} regcred --output 'jsonpath={.data.\.dockerconfigjson}' | base64 --decode | jq ".auths[\"${PRIVATE_REGISTRY_URL}\"]"
    shipa app deploy --app dashboard --image ${PRIVATE_REGISTRY_URL}/shipasoftware/dashboard:v${SHIPA_DASHBOARD_VERSION} --private-image
}

export SHIPA_REPO_NAME="shipa-helm-rc"
export SHIPA_VERSION="1.3.0-rc-12"
export SHIPA_DASHBOARD_VERSION="1.3.0-rc-9"
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

initializeNamespace "${SHIPA_NAMESPACE}"
initializeNamespace "shipa"
installMongoChart
installShipaChart
getShipaLoginInfo
setupShipaCli

read -p "Redeploy the dashboard app using private registry (y/N)? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    redeployDashboardFromArtifactory
fi
