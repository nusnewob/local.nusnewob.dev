#!/usr/bin/env bash -x

set -uo pipefail
set -e

INSTALL_DIR=$(dirname -- ${BASH_SOURCE[0]})

if [ $(kind get clusters | grep -c $(yq '.name' ${INSTALL_DIR}/kind-master.yaml)) == 0 ]; then
  kind create cluster --config kind-master.yaml
  gsed -i "s/0.0.0.0/localhost/g" ${HOME}/.kube/config
else
  kubectx kind-$(yq '.name' ${INSTALL_DIR}/kind-master.yaml)
fi

if [ $(helm list -Aa -o yaml | yq '.[] | select(.name==("fleet")).status') != "deployed" ]; then
  helm repo add fleet https://rancher.github.io/fleet-helm-charts/
  helm install fleet-crd --create-namespace --namespace fleet-system fleet/fleet-crd
  helm install fleet --create-namespace --namespace fleet-system fleet/fleet
fi

kubectl apply -f fleet/workspaces/local.yaml
kubectl apply -f fleet/workspaces/downstream.yaml

#
# Downstream initiated fleet cluster registration
#
CLUSTER_CLIENT_ID=$(echo ${RANDOM} | md5sum | head -c 20)
kubectl apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: Cluster
metadata:
  name: slave
  namespace: fleet-downstream
spec:
  clientID: ${CLUSTER_CLIENT_ID}
EOF

while [ ! kubectl -n fleet-downstream get secret fleet-downstream ]; do sleep 3; done
kubectl --namespace fleet-downstream get secret fleet-downstream -o 'jsonpath={.data.values}' | base64 --decode > .tmp/values.yaml
yq '.clusters[] | select(.name == "kind-k8s.local.nusnewob.dev").cluster.certificate-authority-data' ~/.kube/config | base64 -d > .tmp/ca.pem

if [ $(kind get clusters | grep -c $(yq '.name' ${INSTALL_DIR}/kind-slave.yaml)) == 0 ]; then
  kind create cluster --config kind-slave.yaml
  gsed -i "s/0.0.0.0/localhost/g" ${HOME}/.kube/config
else
  kubectx kind-$(yq '.name' ${INSTALL_DIR}/kind-slave.yaml)
fi

if [ $(helm list -Aa -o yaml | yq '.[] | select(.name==("fleet-agent")).status') != "deployed" ]; then
  helm install --kube-context kind-slave --create-namespace -n fleet-system \
    --values .tmp/values.yaml \
    --set-string labels.downstream=true --set-string labels.env=dev \
    --set-file apiServerCA=.tmp/ca.pem \
    --set apiServerURL="https://k8s.local.nusnewob.dev-control-plane:6443" \
    --set clientID="${CLUSTER_CLIENT_ID}" \
    fleet-agent fleet/fleet-agent
fi

while [ helm list -Aa -o yaml | yq '.[] | select(.chart=="crossplane-provider-*").status' != "deployed" && ! kubectl get providers.pkg.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all' ]; do sleep 3; done
for CREDENTIAL in ${INSTALL_DIR}/private/*.json; do
  PROVIDER_NAME=$(basename ${CREDENTIAL%.*})
  if [ ! kubectl -n crossplane-system get secret provider-${PROVIDER_NAME} ]; then
    kubectl -n crossplane-system create secret generic provider-${PROVIDER_NAME} --from-file=credentials.json=${CREDENTIAL}
  fi
done
kubectl apply -f ${INSTALL_DIR}/test
