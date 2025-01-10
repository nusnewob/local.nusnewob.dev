#!/usr/bin/env bash

kind create cluster --config kind.yaml

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane --create-namespace --namespace crossplane-system --wait crossplane-stable/crossplane

helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm install fleet-crd --create-namespace --namespace fleet-system --wait fleet/fleet-crd
helm install fleet --create-namespace --namespace fleet-system --wait fleet/fleet

kubectl create ns fleet-local
kubectl apply -f fleet/workspaces/local/gitrepo.yaml
kubectl create ns fleet-downstream
kubectl apply -f fleet/workspaces/downstream/gitrepo.yaml

WAIT_PROVIDER=$(kubectl get providers.pkg.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all')
WAIT_HELM=$(kubectl get releases.helm.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all')
while [[ $WAIT_PROVIDER == "true" && $WAIT_HELM == "true" ]]; do
  sleep 3
  WAIT_PROVIDER=$(kubectl get providers.pkg.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all')
  WAIT_HELM=$(kubectl get releases.helm.crossplane.io -o yaml | yq '[.items[].status.conditions[].status] | all')
done

export CLUSTER_TOPOLOGY=true
export EXP_MACHINE_POOL=true
export EXP_CLUSTER_RESOURCE_SET=true
clusterctl init --infrastructure=docker

WAIT_CAPI=$(kubectl get deploy -A -o yaml | yq '.items[].status.conditions[].status')
while [[ $WAIT_CAPI == "true" ]]; do
  sleep 3
  WAIT_CAPI=$(kubectl get deploy -A -o yaml | yq '.items[].status.conditions[].status')
done

kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/refs/heads/main/test/infrastructure/docker/templates/clusterclass-quick-start.yaml

export CLUSTER_NAME=slave.nusnewob.dev
export NAMESPACE=fleet-downstream
export KUBERNETES_VERSION=v1.32.0
clusterctl generate cluster slave.nusnewob.dev --kubernetes-version ${KUBERNETES_VERSION} --from https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/refs/heads/main/test/infrastructure/docker/templates/cluster-template-development.yaml | kubectl apply -f -
