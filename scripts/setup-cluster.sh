#!/bin/sh
# Bootstraps a kind cluster wired to a local registry, then installs
# cert-manager, Strimzi (Kafka), and the in-cluster Redis used by the harness.
# Idempotent on the registry; the kind cluster is created fresh.
set -o errexit

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export TARGET_OS=linux
export TARGET_ARCH=arm64
export GOOS=linux
export GOARCH=arm64
export LOG_LEVEL=debug

# 1. Create registry container unless it already exists
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
    registry:2.7
fi

# 2. Create kind cluster
kind create cluster --config "$SCRIPT_DIR/kind-cluster-config.yaml"

# 3. Wire registry alias into containerd on every node
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

# 4. Connect the registry to the kind network if not already
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# 5. Document the local registry (KEP-1755)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# 6. Cert Manager (required by Dapr)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml

# 7. Strimzi + single-node Kafka cluster
kubectl create namespace kafka
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
echo "Waiting for Strimzi cluster operator…"
kubectl wait --for=condition=Available deployment/strimzi-cluster-operator \
  --namespace kafka --timeout=300s
kubectl apply -f https://strimzi.io/examples/latest/kafka/kafka-single-node.yaml -n kafka
echo "Waiting for Kafka cluster…"
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=600s -n kafka

# 8. In-cluster Redis (used by dapr-kafka harness for SADD/SREM tracking)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["--save", "", "--appendonly", "no"]
          ports:
            - containerPort: 6379
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 1
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
EOF
kubectl rollout status deploy/redis --timeout=60s

echo
echo "Cluster ready. Next:"
echo "  dapr init -k                   # install Dapr control plane"
echo "  make build push deploy         # in the dapr-kafka repo"
