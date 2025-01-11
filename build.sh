#!/usr/bin/env bash -xe

kind create cluster --config kind-slave.yaml
kind create cluster --config kind-master.yaml
gsed -i "s/0.0.0.0/localhost/g" ${HOME}/.kube/config

helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane --create-namespace --namespace crossplane-system crossplane-stable/crossplane

helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm install fleet-crd --create-namespace --namespace fleet-system fleet/fleet-crd
helm install fleet --create-namespace --namespace fleet-system fleet/fleet

kubectl apply -f fleet/workspaces/local/gitrepo.yaml
kubectl apply -f fleet/workspaces/downstream/gitrepo.yaml

#
# Downstream initiated fleet cluster registration
#
while ! kubectl -n fleet-downstream  get secret fleet-downstream; do sleep 5; done
kubectl --namespace fleet-downstream get secret fleet-downstream -o 'jsonpath={.data.values}' | base64 --decode > .tmp/values.yaml
yq '.clusters[] | select(.name == "kind-k8s.local.nusnewob.dev").cluster.certificate-authority-data' ~/.kube/config | base64 -d > .tmp/ca.pem

helm install --kube-context kind-slave --create-namespace -n fleet-system \
  --values .tmp/values.yaml \
  --set-string labels.example=true --set-string labels.env=dev \
  --set-file apiServerCA=.tmp/ca.pem \
  --set apiServerURL="https://k8s.local.nusnewob.dev-control-plane:6443" \
  fleet-agent fleet/fleet-agent
