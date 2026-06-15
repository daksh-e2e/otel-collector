#!/usr/bin/env bash
# E2E Observability Agent — Kubernetes installer
# Usage:
#   E2E_API_KEY=<key> bash -c "$(curl -fsSL https://raw.githubusercontent.com/daksh-e2e/otel-collector/test/install-k8s.sh)"
#
# Optional overrides:
#   E2E_CLUSTER_NAME=<name>   — human name for this cluster (default: current kubectl context)
#   E2E_NAMESPACE=<ns>        — namespace to deploy into (default: e2e-observability)

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
REGISTER_API="http://172.16.230.168:31881/v1/install/register"
GATEWAY_ENDPOINT="172.16.230.168:31318"
COLLECTOR_IMAGE="otel/opentelemetry-collector-contrib:0.105.0"
NAMESPACE="${E2E_NAMESPACE:-$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null | tr -d '[:space:]')}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[e2e-k8s-install] $*"; }
error() { echo "[e2e-k8s-install] ERROR: $*" >&2; exit 1; }

# ns_flag: returns "-n <namespace>" when namespace is set, empty string otherwise.
ns_flag() { [ -n "${NAMESPACE:-}" ] && echo "-n ${NAMESPACE}" || echo ""; }

parse_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r ".${field} // empty"
  else
    echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | cut -d'"' -f4 || true
  fi
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not found."
  command -v curl    >/dev/null 2>&1 || error "curl is required but not found."
  [ -n "${E2E_API_KEY:-}" ] || error "E2E_API_KEY is not set."
  kubectl cluster-info >/dev/null 2>&1 || error "kubectl cannot reach the cluster. Check your kubeconfig."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "Running preflight checks..."
  preflight
  info "Preflight passed."

  # Cluster name — used as hostname so each cluster gets its own log group.
  local cluster_name
  cluster_name="${E2E_CLUSTER_NAME:-$(kubectl config current-context 2>/dev/null || echo k8s-cluster)}"
  # Sanitize: lowercase, replace non-alphanumeric with hyphen, strip leading/trailing hyphens.
  cluster_name=$(echo "$cluster_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63)
  info "Cluster name: ${cluster_name}"

  # ── Phase 1: Register ───────────────────────────────────────────────────
  info "Registering with E2E Observability API..."
  REGISTER_RESPONSE=$(curl -fsSL -X POST "${REGISTER_API}" \
    -H "Content-Type: application/json" \
    -d "{
      \"apiKey\":       \"${E2E_API_KEY}\",
      \"resourceType\": \"k8s\",
      \"hostname\":     \"${cluster_name}\"
    }") || error "Registration API call failed. Check your E2E_API_KEY and network connectivity."

  E2E_TOKEN=$(parse_field    "${REGISTER_RESPONSE}" "ingestion_token")
  E2E_LOG_GROUP=$(parse_field "${REGISTER_RESPONSE}" "log_group")
  E2E_PROJECT_ID=$(parse_field "${REGISTER_RESPONSE}" "project_id")

  [ -n "${E2E_TOKEN:-}"      ] || error "Registration failed: ingestion_token missing."
  [ -n "${E2E_LOG_GROUP:-}"  ] || error "Registration failed: log_group missing."
  [ -n "${E2E_PROJECT_ID:-}" ] || error "Registration failed: project_id missing."

  info "Registered. Log group: ${E2E_LOG_GROUP}"

  # ── Phase 2: Apply K8s resources ────────────────────────────────────────
  local ns_display="${NAMESPACE:-default}"
  info "Deploying E2E OTel Collector to namespace '${ns_display}'..."

  # Build namespace block only when a namespace was specified.
  local ns_block=""
  local ns_meta=""
  if [ -n "${NAMESPACE:-}" ]; then
    ns_block="apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: e2e-observability
---"
    ns_meta="  namespace: ${NAMESPACE}"
  fi

  kubectl apply -f - <<EOF
${ns_block}
# ── RBAC ───────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ServiceAccount
metadata:
  name: e2e-otel-collector
${ns_meta}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: e2e-otel-collector
rules:
  - apiGroups: [""]
    resources: [pods, namespaces, nodes, endpoints]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes/stats, nodes/proxy, nodes/metrics]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [replicasets, deployments, statefulsets, daemonsets]
    verbs: [get, list, watch]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: e2e-otel-collector
subjects:
  - kind: ServiceAccount
    name: e2e-otel-collector
    namespace: ${NAMESPACE:-default}
roleRef:
  kind: ClusterRole
  name: e2e-otel-collector
  apiGroup: rbac.authorization.k8s.io

---
# ── Credentials secret ─────────────────────────────────────────────────────
apiVersion: v1
kind: Secret
metadata:
  name: e2e-otel-credentials
${ns_meta}
type: Opaque
stringData:
  token: "${E2E_TOKEN}"
  log_group: "${E2E_LOG_GROUP}"
  project_id: "${E2E_PROJECT_ID}"

---
# ── OTel Collector config ──────────────────────────────────────────────────
apiVersion: v1
kind: ConfigMap
metadata:
  name: e2e-otel-config
${ns_meta}
data:
  config.yaml: |
    extensions:
      health_check:
        endpoint: "0.0.0.0:13133"
      file_storage:
        directory: /var/lib/e2e-otel-collector
        timeout: 10s

    receivers:
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        include_file_path: true
        include_file_name: false
        start_at: end
        storage: file_storage
        operators:
          - type: container
            id: container-parser
            add_metadata_from_filepath: true

      hostmetrics:
        collection_interval: 30s
        root_path: /hostfs
        scrapers:
          cpu:
            metrics:
              system.cpu.utilization:
                enabled: true
          memory:
            metrics:
              system.memory.utilization:
                enabled: true
          disk: {}
          network: {}
          load: {}
          filesystem:
            exclude_mount_points:
              mount_points: ["/dev/*", "/proc/*", "/sys/*", "/hostfs/dev/*", "/hostfs/proc/*", "/hostfs/sys/*"]
              match_type: regexp
            exclude_fs_types:
              fs_types: [autofs, binfmt_misc, bpf, cgroup2, configfs, debugfs,
                         devpts, devtmpfs, fusectl, hugetlbfs, mqueue, nsfs,
                         overlay, proc, procfs, pstore, securityfs, sysfs]
              match_type: strict

      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: "https://\${env:NODE_IP}:10250"
        insecure_skip_verify: true
        metric_groups:
          - node
          - pod
        extra_metadata_labels:
          - container.id
        k8s_api_config:
          auth_type: serviceAccount
        metrics:
          k8s.node.cpu.usage:
            enabled: true
          k8s.pod.cpu.usage:
            enabled: true

    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 200
        spike_limit_mib: 50

      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
          labels:
            - tag_name: service.name
              key: app
              from: pod
            - tag_name: service.name
              key: app.kubernetes.io/name
              from: pod
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: resource_attribute
                name: k8s.pod.name
              - from: resource_attribute
                name: k8s.namespace.name

      resource/tenant:
        attributes:
          - key: hostname
            value: "\${env:NODE_NAME}"
            action: upsert
          - key: host.name
            value: "\${env:NODE_NAME}"
            action: upsert
          - key: log_group
            value: "\${env:E2E_LOG_GROUP}"
            action: upsert
          - key: project_id
            value: "\${env:E2E_PROJECT_ID}"
            action: upsert

      batch:
        timeout: 1s
        send_batch_size: 512
        send_batch_max_size: 1024

    exporters:
      otlp/gateway:
        endpoint: "${GATEWAY_ENDPOINT}"
        tls:
          insecure: true
        headers:
          authorization: "Bearer \${env:E2E_TOKEN}"
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    service:
      extensions: [health_check, file_storage]
      pipelines:
        logs:
          receivers: [filelog]
          processors: [memory_limiter, k8sattributes, resource/tenant, batch]
          exporters: [otlp/gateway]
        metrics/infrastructure:
          receivers: [hostmetrics, kubeletstats]
          processors: [memory_limiter, resource/tenant, batch]
          exporters: [otlp/gateway]

---
# ── DaemonSet ──────────────────────────────────────────────────────────────
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: e2e-otel-collector
${ns_meta}
  labels:
    app: e2e-otel-collector
spec:
  selector:
    matchLabels:
      app: e2e-otel-collector
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: e2e-otel-collector
    spec:
      serviceAccountName: e2e-otel-collector
      tolerations:
        - operator: Exists
      containers:
        - name: collector
          image: ${COLLECTOR_IMAGE}
          args: ["--config=/etc/otel/config.yaml"]
          securityContext:
            runAsUser: 0
            readOnlyRootFilesystem: false
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: E2E_TOKEN
              valueFrom:
                secretKeyRef:
                  name: e2e-otel-credentials
                  key: token
            - name: E2E_LOG_GROUP
              valueFrom:
                secretKeyRef:
                  name: e2e-otel-credentials
                  key: log_group
            - name: E2E_PROJECT_ID
              valueFrom:
                secretKeyRef:
                  name: e2e-otel-credentials
                  key: project_id
          ports:
            - containerPort: 13133
              name: health
          resources:
            requests:
              cpu: 100m
              memory: 200Mi
            limits:
              cpu: 500m
              memory: 500Mi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 30
            periodSeconds: 30
          volumeMounts:
            - name: config
              mountPath: /etc/otel
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: storage
              mountPath: /var/lib/e2e-otel-collector
            - name: hostfs
              mountPath: /hostfs
              readOnly: true
              mountPropagation: HostToContainer
      volumes:
        - name: config
          configMap:
            name: e2e-otel-config
        - name: varlogpods
          hostPath:
            path: /var/log/pods
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
        - name: storage
          hostPath:
            path: /var/lib/e2e-otel-collector
            type: DirectoryOrCreate
        - name: hostfs
          hostPath:
            path: /
EOF

  info "Waiting for DaemonSet to roll out..."
  # shellcheck disable=SC2046
  kubectl rollout status daemonset/e2e-otel-collector $(ns_flag) --timeout=120s

  # ── Done ──────────────────────────────────────────────────────────────────
  local node_count
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  local ns_display="${NAMESPACE:-default}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " E2E Observability Agent installed on K8s!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Cluster:   ${cluster_name}"
  echo " Namespace: ${ns_display}"
  echo " Nodes:     ${node_count}"
  echo " Log group: ${E2E_LOG_GROUP}"
  echo " Project:   ${E2E_PROJECT_ID}"
  echo ""
  echo " Status:  kubectl get daemonset e2e-otel-collector $(ns_flag)"
  echo " Logs:    kubectl logs -l app=e2e-otel-collector $(ns_flag) -f"
  echo " Health:  kubectl exec $(ns_flag) daemonset/e2e-otel-collector -- wget -qO- localhost:13133"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
