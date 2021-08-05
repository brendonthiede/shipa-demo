#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

source ${PROJECTS_ROOT}/openstack-ci/scripts/lib/_common.sh

_vault_content="$(get_jenkins_openstack_env_secret_from_prd_vault "tst" "shipa-demo" | jq -r '.data')"
export ADMIN_PASSWORD="$(echo "${_vault_content}" | jq -r '.adminPassword')"
export LICENSE_KEY="$(echo "${_vault_content}" | jq -r '.license')"

"${DIR}/install.sh" "${ADMIN_PASSWORD}" "${LICENSE_KEY}"