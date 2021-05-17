#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

pushd "${DIR}"

mkdir -p logs

for _ns in shipa shipa-system; do
    for _po in $(kubectl get po -n ${_ns} -o jsonpath='{..metadata.name}'); do
        for _container in $(kubectl get po -n ${_ns} ${_po} -o 'jsonpath={.spec.containers[].name} {.spec.initContainers[].name}{"\n"}'); do
            echo "[INFO] Pulling logs for ${_ns}.${_po}.${_container}"
            _log_file="logs/${_ns}.${_po}.${_container}.log"
            kubectl logs -n ${_ns} ${_po} -c ${_container} >${_log_file}
        done
    done
done

tar -zcf logs.tgz logs
echo "[INFO] $(date "+%Y-%m-%d %H:%M:%S") Logs are available at ${DIR}/logs.tgz"

popd
