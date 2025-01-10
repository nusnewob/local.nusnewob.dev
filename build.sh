#!/usr/bin/env bash -xe

kind create cluster --config kind.yaml

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane --create-namespace --namespace crossplane-system crossplane-stable/crossplane

helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm install fleet-crd --create-namespace --namespace fleet-system fleet/fleet-crd
helm install fleet --create-namespace --namespace fleet-system fleet/fleet

kubectl apply -f fleet/workspaces/local/gitrepo.yaml
kubectl apply -f fleet/workspaces/downstream/gitrepo.yaml

while [[ ${WAIT_PROVIDER:-false} == "false" || ${WAIT_HELM:-false} == "false" ]]; do
  sleep 3
  WAIT_PROVIDER=$(kubectl get providers.pkg.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all')
  WAIT_HELM=$(kubectl get crd -o yaml | yq '[.items[].metadata.name] | contains(["releases.helm.crossplane.io"])')
done
while [[ ${WAIT_HELM_RELEASE:-false} == "false" ]]; do
  sleep 3
  WAIT_HELM_RELEASE=$(kubectl get releases.helm.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all and length > 1')
done

export CLUSTER_TOPOLOGY=true
export EXP_MACHINE_POOL=true
export EXP_CLUSTER_RESOURCE_SET=true
clusterctl init --wait-providers --infrastructure=docker

while [[ ${WAIT_CAPI_WEBHOOK:-false} == "false" ]]; do
  sleep 3
  WAIT_CAPI_WEBHOOK=$(kubectl get svc -A -o yaml | yq '[.items[].metadata.name] | contains(["capi-webhook-service","capd-webhook-service","capi-kubeadm-control-plane-webhook-service","capi-kubeadm-bootstrap-webhook-service"])')
done

NAMESPACE=fleet-downstream
kubectl apply -n ${NAMESPACE} -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/refs/heads/main/test/infrastructure/docker/templates/clusterclass-quick-start.yaml

while [[ ${WAIT_CAPI_CLUSTER_CLASS:-false} == "false" ]]; do
  sleep 3
  WAIT_CAPI_CLUSTER_CLASS=$(kubectl get clusterclasses.cluster.x-k8s.io -o yaml | yq '[.items[].status.conditions[].status] | all')
done

CLUSTER_NAME=slave.local.nusnewob.dev
clusterctl generate cluster ${CLUSTER_NAME} -n ${NAMESPACE} --kubernetes-version $(kubectl version -o yaml | yq '.serverVersion.gitVersion') --from https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/refs/heads/main/test/infrastructure/docker/templates/cluster-template-development.yaml | kubectl apply -f -
