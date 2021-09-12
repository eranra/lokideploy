#!/bin/bash

# create loki project
create_loki_project() {
  echo "==> creating loki project"
  oc adm new-project loki
  oc project loki
}

# delete loki project if it exists (to get new fresh deployment)
delete_loki_project_if_exists() {
PROJECT_LOKI=$(oc get project | grep loki)
if [ -n "$PROJECT_LOKI" ]; then
  echo "--> Deleting loki namespace"
  oc delete project loki
  while : ; do
    PROJECT_LOKI=$(oc get project | grep loki)
    if [ -z "$PROJECT_LOKI" ]; then break; fi
    sleep 1
  done
fi
}

# add helm to repository
add_helm_repository() {
  echo "adding helm repository"
  helm repo add grafana https://grafana.github.io/helm-charts
}

# deploy loki (distributed)
deploy_loki_distributed_helm_chart() {
  ingester_replicas=$1
  distributor_replicas=$2
  querier_replicas=$3
  query_frontend_replicas=$4
  s3_endpoint=$5

  echo "==> deploying loki (using helm)"
  echo "Replicas:"
  echo "ingester_replicas=$ingester_replicas"
  echo "distributor_replicas=$distributor_replicas"
  echo "querier_replicas=$querier_replicas"
  echo "query_frontend_replicas=$query_frontend_replicas"
  helm delete loki -n loki
  cat > tmp/loki-values.yaml <<- EOF
loki:
  config: |
    auth_enabled: true

    server:
      log_level: info
      # Must be set to 3100
      http_listen_port: 3100
      grpc_server_max_recv_msg_size: 10485760000 # 10 GB
      grpc_server_max_send_msg_size: 10485760000 # 10 GB
      http_server_read_timeout: 2m
      http_server_write_timeout: 2m
      graceful_shutdown_timeout: 2m

    tracing:
      enabled: false

    distributor:
      ring:
        kvstore:
          store: memberlist

    ingester:
      max_transfer_retries: 10
      flush_check_period: 30s
      flush_op_timeout: 3m
      concurrent_flushes: 64
      chunk_block_size: 15728640
      chunk_encoding: lz4
      chunk_idle_period: 1m
      chunk_retain_period: 0m
      max_chunk_age: 5m
      lifecycler:
        ring:
          kvstore:
            store: memberlist
          replication_factor: 1
        final_sleep: 0s
        min_ready_duration: 10s

    memberlist:
      join_members:
        - {{ include "loki.fullname" . }}-memberlist

    limits_config:
      max_entries_limit_per_query: 0
      ingestion_rate_strategy: global
      reject_old_samples: true
      ingestion_rate_mb: 100
      ingestion_burst_size_mb: 100
      max_cache_freshness_per_query: 1m
      creation_grace_period: 1m
      enforce_metric_name: false

    schema_config:
      configs:
        - from: 2020-09-07
          store: boltdb-shipper
          object_store: aws
          schema: v11
          index:
            prefix: loki_index_
            period: 24h

    storage_config:
      azure:
        request_timeout: 2m
      aws:
        s3: ${s3_endpoint}
        region: us-east-1
        s3forcepathstyle: true
        http_config:
          insecure_skip_verify: true
      index_cache_validity: 40s 
      boltdb_shipper:
        shared_store: s3
        active_index_directory: /var/loki/index
        cache_location: /var/loki/cache  
      
    # query_range:
    #   split_queries_by_interval: 15s

    querier:
      query_timeout: 2m
      query_ingesters_within: 1s
      # 'query_store_only' doesn't exist yet in the latest version
      # query_store_only: true
      engine:
        timeout: 3m
        max_look_back_period: 40s

    frontend_worker:
      frontend_address: {{ include "loki.queryFrontendFullname" . }}:9095
      grpc_client_config:
        max_send_msg_size: 17179869184  # 16GiB

    frontend:
      log_queries_longer_than: 27s
      compress_responses: true
    
global:
  dnsService: kubelet
gateway:
  enabled: false
distributor:
  replicas: ${distributor_replicas}
  affinity: ""
  resources:
    limits:
      cpu: 2
      memory: 2Gi
    requests:
      cpu: 1
      memory: 200Mi
ingester:
  replicas: ${ingester_replicas}
  affinity: ""
  resources:
      limits:
        cpu: 2
      requests:
        cpu: 1
        memory: 200Mi
#        memory: 3Gi
  persistence:
    enabled: true
  terminationGracePeriodSeconds: 5
querier:
  replicas: ${querier_replicas}
  affinity: ""
  resources:
#      limits:
#        cpu: 2
#        memory: 4Gi
      requests:
        cpu: 1
#        memory: 2Gi
        memory: 1000Mi
queryFrontend:
  replicas: ${query_frontend_replicas}
  affinity: ""
  resources:
      limits:
        cpu: 2
      requests:
        cpu: 1
        memory: 1Gi
#        memory: 200Mi
memcachedChunks:
  enabled: false
memcachedFrontend:
  enabled: false
memcachedIndexQueries: 
  enabled: false
memcachedIndexWrites:
  enabled: false
serviceMonitor:
  enabled: true
EOF
  oc adm policy add-scc-to-user privileged -z loki-loki-distributed
  helm upgrade --install loki grafana/loki-distributed --namespace=loki -f tmp/loki-values.yaml
  oc delete -n loki route loki-loki-distributed-query-frontend
  oc expose -n loki service loki-loki-distributed-query-frontend
  oc delete -n loki route loki-loki-distributed-distributor
  oc expose -n loki service loki-loki-distributed-distributor
  oc get route -n loki
}

# deploy grafana
deploy_grafana_helm_chart() {
  echo "==> deploying grafana (using helm)"
  helm delete grafana -n loki
  cat > tmp/grafana-values.yaml <<- EOF
rbac:
  create: false
  pspEnabled: false
adminUser: admin
adminPassword: password
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: loki
      type: loki
      access: proxy
      url: http://loki-loki-distributed-query-frontend.loki.svc.cluster.local:3100
EOF
  oc adm policy add-scc-to-user privileged -z grafana
  helm upgrade --install grafana grafana/grafana --namespace=loki -f tmp/grafana-values.yaml
  oc delete -n loki route grafana
  oc expose -n loki service grafana
  oc get route -n loki
}

# deploy promtail
deploy_promtail_helm_chart() {
  echo "==> deploying promtail (using helm)"
  helm delete promtail -n loki
  cat > tmp/promtail-values.yaml <<- EOF
config:
  logLevel: "info"
  lokiAddress: "http://loki-loki-distributed-distributor.loki.svc.cluster.local:3100/loki/api/v1/push"
containerSecurityContext:
  allowPrivilegeEscalation: true
podSecurityContext:
  runAsUser: 100
  runAsGroup: 100
EOF
  oc adm policy add-scc-to-user privileged -z promtail
  helm upgrade --install promtail grafana/promtail --namespace=loki -f tmp/promtail-values.yaml
  oc patch ds promtail --type=json -p '[{"op": "remove", "path": "/spec/template/spec/securityContext"}]'
  oc patch ds promtail --type=json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/securityContext/privileged", "value":true}]'
}

# enable user workload monitoring 
enable_user_workload_monitoring() {
  echo "==> enable user workload monitoring"
  oc apply -f cluster-monitoring-config.yaml
}

# enable user workload monitoring 
deploy_minio() {
  echo "==> deploy minio"
  oc adm policy add-scc-to-user privileged -z minio-service-account
  oc delete --ignore-not-found=true deployment minio
  oc process -f minio_template.yaml | oc apply -f -
  oc expose -n loki service minio
}

deploy_stress() {

  DEPLOY_YAML=stress_template.yaml
  echo "--> Deploying $DEPLOY_YAML - with ($1 $2 $3 $4 $5)"
  rm -f loki-write-stressor.zip
  rm -f loki-write-stressor
  rm -f loki-write-stressor-split.*
  go build -ldflags "-s -w" go/loki-stressor/loki-write-stressor.go
  zip loki-write-stressor.zip loki-write-stressor
  zip -s 1m loki-write-stressor.zip --out loki-write-stressor-split.zip
  oc delete configmap --ignore-not-found=true loki-write-stressor-binary-zip
  oc delete configmap --ignore-not-found=true loki-write-stressor-binary-z01
  oc create configmap loki-write-stressor-binary-zip --from-file=loki-write-stressor-split.zip
  oc create configmap loki-write-stressor-binary-z01 --from-file=loki-write-stressor-split.z01
  rm -f loki-write-stressor.zip
  rm -f loki-write-stressor
  rm -f loki-write-stressor-split.*

  echo "==> deploy stress"
  oc adm policy add-scc-to-user privileged -z stress-service-account
  oc delete --ignore-not-found=true statefulset write-stress
  oc delete --ignore-not-found=true statefulset query-stress
  oc process -f $DEPLOY_YAML \
    -p write_replicas="$1" \
    -p write_message_per_second="$2" \
    -p write_batch_size="$3" \
    -p query_replicas="$4" \
    -p query_delay="$5" \
    | oc apply -f -
}

# print pod status
print_pods_status() {
  echo -e "\n"
  oc get pods
}

# print usage instructions
print_usage_instructions() {
  GRAFANA_POD=$(oc get pod -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}")
  MINIO_POD=$(oc get pod -l app=minio -o jsonpath="{.items[0].metadata.name}" 2>/dev/null )

  echo -e "Waiting for $GRAFANA_POD to become ready"
  while : ; do
    POD_READY=$(oc get pod "$GRAFANA_POD" | grep Running)
    if [ -n "$POD_READY" ]; then break; fi
    sleep 1
  done
  
  GRAFANA_ROUTE_URL=$(oc get route grafana -o jsonpath="{.spec.host}")
  echo -e "\nopen browser agasint http://$GRAFANA_ROUTE_URL\n"
  echo -e "user: admin password: password\n"
  echo -e "\n\nexpore loki data in minio:: oc logs -n loki -f $MINIO_POD -c minio-mc"
  echo -e "\n\nExample: under explore tab change datasource to \"Loki\", change time to \"last 24 hours\" and run query like:\n"
  echo -e " {job=\"openshift-dns/dns-default\"}"
  echo -e " {app=\"loki-distributed\"} | logfmt | entries > 1"
  echo -e "\n\n to see resource utilization use: kubectl top pod --namespace=loki --sort-by=cpu | head -n 20;"
  echo -e "\n\n change stress example: source ./deploy_functions.sh ; deploy_stress 5 10000 1000  0 30"
  
}


