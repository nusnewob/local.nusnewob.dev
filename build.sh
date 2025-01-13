#!/usr/bin/env bash -xe

kind create cluster --config kind-master.yaml
gsed -i "s/0.0.0.0/localhost/g" ${HOME}/.kube/config

helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm install fleet-crd --create-namespace --namespace fleet-system fleet/fleet-crd
helm install fleet --create-namespace --namespace fleet-system fleet/fleet

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

while ! kubectl -n fleet-downstream get secret fleet-downstream; do sleep 3; done
kubectl --namespace fleet-downstream get secret fleet-downstream -o 'jsonpath={.data.values}' | base64 --decode > .tmp/values.yaml
yq '.clusters[] | select(.name == "kind-k8s.local.nusnewob.dev").cluster.certificate-authority-data' ~/.kube/config | base64 -d > .tmp/ca.pem

kind create cluster --config kind-slave.yaml
gsed -i "s/0.0.0.0/localhost/g" ${HOME}/.kube/config

helm install --kube-context kind-slave --create-namespace -n fleet-system \
  --values .tmp/values.yaml \
  --set-string labels.downstream=true --set-string labels.env=dev \
  --set-file apiServerCA=.tmp/ca.pem \
  --set apiServerURL="https://k8s.local.nusnewob.dev-control-plane:6443" \
  --set clientID="${CLUSTER_CLIENT_ID}" \
  fleet-agent fleet/fleet-agent
