#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"


echo "# --------------------------------------"
echo "# Check installed packages"
echo "# --------------------------------------"
KUBECTL_SUCCESS="The kubectl package is installed."
KUBECTL_ERROR="The kubectl package is not installed. Please follow this guide https://kubernetes.io/docs/tasks/tools/install-kubectl/"
type kubectl &>/dev/null && echo "${KUBECTL_SUCCESS}" || echo "${KUBECTL_ERROR}"

HELM_SUCCESS="The helm package is installed."
HELM_ERROR="The helm package is not installed. Please follow this guide https://helm.sh/docs/intro/install/"
type helm &>/dev/null && echo "${HELM_SUCCESS}" || echo "${HELM_ERROR}"

echo "┌─────────────────────────────────────┐"
echo "⟾ Check default namespace for kubectl │"
echo "└─────────────────────────────────────┘"
WILL_STOP_PODS="n"
KUBECTL_PODS="The default namespace is running elements in kubectl."
if [[ "$(kubectl get all -o custom-columns=NAME:metadata.name --no-headers | wc -l)" -gt 1 ]]; then
  echo "${KUBECTL_PODS}"
  kubectl get all
  read -rp "Do you want to stop all of these pods, services, etc? (y/N): " WILL_STOP_PODS
fi
if [[ "${WILL_STOP_PODS,,}" == "y" ]]; then
  while true; do
    echo ""
    echo "⤑ Stopping all pods; this might take a few minutes..."
    helm uninstall daemons --debug 2>/dev/null || true
    helm uninstall server --debug 2>/dev/null || true
    helm uninstall postgres --debug 2>/dev/null || true
    kubectl delete job daemons-renew-fts-proxy-on-helm-install 2>/dev/null || true
    kubectl delete pvc data-postgres-postgresql-0 2>/dev/null || true
    kubectl delete -f ../fts.yaml --all=true --recursive=true
    kubectl delete -f ../ftsdb.yaml --all=true --recursive=true
    kubectl delete -f ../xrd.yaml --all=true --recursive=true
    kubectl delete -f ../client.yaml --all=true --recursive=true
    kubectl delete -f ../init-pod.yaml --all=true --recursive=true
    kubectl delete -k ../secrets
    kubectl get all
    if [[ "$(kubectl get all -o custom-columns=NAME:metadata.name --no-headers | wc -l)" -le 1 ]]; then
      break
    fi
    sleep 4
  done
    echo ""
    echo "Pods stopped."
fi

echo ""
echo "# --------------------------------------"
echo "# Start local environment"
echo "# --------------------------------------"

echo "┌──────────────────────────┐"
echo "⟾ Add repositories to helm │"
echo "└──────────────────────────┘"
helm repo add stable https://charts.helm.sh/stable
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add rucio https://rucio.github.io/helm-charts
helm repo update

echo "┌──────────────────────┐"
echo "⟾ Apply secrets        │"
echo "└──────────────────────┘"
kubectl apply -k ../secrets

echo "┌────────────────────────┐"
echo "⟾ Helm: Install Postgres │"
echo "└────────────────────────┘"
KUBECTL_HAS_PVC="The kubectl has the Postgres PVC. Deleting."
kubectl get pvc data-postgres-postgresql-0 &>/dev/null || false && {
  echo "${KUBECTL_HAS_PVC}"
  kubectl delete pvc data-postgres-postgresql-0
}
helm delete postgres 2>/dev/null || true
helm install postgres bitnami/postgresql -f ../values-postgres.yaml

echo "┌──────────────────────────┐"
echo "⟾ kubectl: Set up Postgres │"
echo "└──────────────────────────┘"
echo "⤑ Waiting until the Postgres is set up; this might take a few minutes..."
kubectl rollout status statefulset postgres-postgresql

echo "┌─────────────────────────────────┐"
echo "⟾ kubectl: Rucio - Init container │"
echo "└─────────────────────────────────┘"
kubectl delete pod init 2>/dev/null || true
kubectl apply -f ../init-pod.yaml
echo "⤑ Waiting until the Rucio init container is set up; this might take a few minutes..."
kubectl wait --timeout=120s --for=condition=Ready pod/init

echo "┌──────────────────────────────────────────┐"
echo "⟾ kubectl: Logs for Rucio - Init container │"
echo "└──────────────────────────────────────────┘"
kubectl logs init

echo "┌────────────────────────────┐"
echo "⟾ Helm: Install Rucio server │"
echo "└────────────────────────────┘"
helm delete server 2>/dev/null || true
helm install server rucio/rucio-server -f ../values-server.yaml
kubectl rollout status deployment server-rucio-server

echo "┌────────────────────────────────┐"
echo "⟾ kubectl: Logs for Rucio server │"
echo "└────────────────────────────────┘"
kubectl logs deployment/server-rucio-server -c rucio-server

echo "┌───────────────────────────────────┐"
echo "⟾ kubectl: Install client container │"
echo "└───────────────────────────────────┘"
kubectl apply -f ../client.yaml
kubectl wait --timeout=120s --for=condition=Ready pod/client

echo "┌─────────────────────────────────┐"
echo "⟾ kubectl: Check client container │"
echo "└─────────────────────────────────┘"
kubectl exec client -it -- /etc/profile.d/rucio_init.sh
kubectl exec client -it -- rucio whoami

echo "┌─────────────────────────────────────────┐"
echo "⟾ kubectl: Install XRootD storage systems │"
echo "└─────────────────────────────────────────┘"
kubectl apply -f ../xrd.yaml
XRD_CONTAINERS=(xrd1 xrd2 xrd3)
echo "XRD_CONTAINERS: ${XRD_CONTAINERS[*]}"
for XRD_CONTAINER in "${XRD_CONTAINERS[@]}"; do
  kubectl --timeout=120s wait --for=condition=Ready pod/$XRD_CONTAINER
done

echo "┌───────────────────────────────────────┐"
echo "⟾ kubectl: Install FTS database (MySQL) │"
echo "└───────────────────────────────────────┘"
kubectl apply -f ../ftsdb.yaml
kubectl rollout status deployment fts-mysql

echo "┌────────────────────────────────────────┐"
echo "⟾ kubectl: Logs for FTS database (MySQL) │"
echo "└────────────────────────────────────────┘"
kubectl logs deployment/fts-mysql

echo "┌──────────────────────┐"
echo "⟾ kubectl: Install FTS │"
echo "└──────────────────────┘"
kubectl apply -f ../fts.yaml
kubectl rollout status deployment fts-server

echo "┌───────────────────────┐"
echo "⟾ kubectl: Logs for FTS │"
echo "└───────────────────────┘"
kubectl logs deployment/fts-server

echo "┌───────────────────────┐"
echo "⟾ helm: Install daemons │"
echo "└───────────────────────┘"
helm delete daemons 2>/dev/null || true
echo "⤑ Waiting until the daemons are set up; this might take a few minutes..."
helm install daemons rucio/rucio-daemons -f ../values-daemons.yaml
for DAEMON in $(kubectl get deployment -l='app-group=rucio-daemons' -o name); do
    kubectl rollout status $DAEMON
done

echo""
echo""
echo""
echo "*** Rucio deployment complete. ***"
