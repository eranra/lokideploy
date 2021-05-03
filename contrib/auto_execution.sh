#!/bin/bash

auto_show_usage() {
  echo "
usage: auto_execution [options]
  options:

    -h,  --help                           Show usage
    --write_batch_min=[num]               Minimum batch size (default: 1)
    --write_batch_max=[num]               Maximum batch size (default: 15)
    --write_batch_step=[num]              Batch step (default: 2)
    --write_msg_per_sec=[num]             MessagesPerSecond (default: 2000)
    --write_replicas_min=[num]            Minimum batch size (default: 1)
    --write_replicas_max=[num]            Maximum batch size (default: 3)
    --loki_replicas_min=[num]             Minimum loki replicas (default:2)
    --loki_replicas_max=[num]             Maximum loki replicas (default:3)
"
  exit 0
}

auto_show_configuration() {

echo "
Note: get more deployment options with -h

Configuration (Automatic execution):
-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=-
Write batch minimum --> $write_batch_min
Write batch maximum --> $write_batch_max
Write batch step --> $write_batch_step
Replications minimum --> $replicas_min
Replications maximum --> $replicas_max
"
}

initial_deploy() {
  collector="none"
  stress_profile="none"
  replicas=2
  deploy
}

average_csv_line() {
  csv="$1"
  pod_pre="$2"
  AVG_CPU=$(echo "$csv" | grep "$pod_pre" | awk -F',' '{sum+=$5; ++n} END { print int(sum/n) }')
  AVG_MEM=$(echo "$csv" | grep "$pod_pre" | awk -F',' '{sum+=$6; ++n} END { print int(sum/n) }')
  AVG_CSV="$csv_line_pre$pod_pre-avg,avg-loki,$AVG_CPU,$AVG_MEM"
  echo "$AVG_CSV"
}

collect_results() {
  csv_line_pre=$1
  csv_filename=$2
  # wait for enough results
  echo -e "===> Collecting results for ($csv_line_pre) into $csv_filename"
  echo -e "===> Warm up: waiting $warmup_wait seconds"
  sleep "$warmup_wait"
  echo -e "===> Waiting for enough results"
  RESULTS_COUNT=0
  LOG_RESULTS="
      ======>>> RESULTS of current execution
      -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=
      "
  while : ; do
    RESULTS=$(kubectl top pod --namespace=loki)
    LOG_RESULTS=$(printf "%s\n\n%s\n" "$LOG_RESULTS" "$RESULTS")
    CSV_RESULTS="$(kubectl top pod --namespace=loki --containers | sed -r 's|Mi | |' | sed -r 's| ([0-9]+)m|\1|' | tr -s "[:blank:]" "," | sed -r 's|^|'$csv_line_pre'|g')"

    ## echo "$CSV_RESULTS" >> "$csv_filename"

    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "loki-loki-distributed-distributor")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "loki-loki-distributed-ingester")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "loki-loki-distributed-querier")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "loki-loki-distributed-query-frontend")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "minio")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "grafana")
    echo "$AVG_LINE" >> "$csv_filename"
    AVG_LINE=$(average_csv_line "$CSV_RESULTS" "write-stress")
    echo "$AVG_LINE" >> "$csv_filename"

    RESULTS_COUNT=$(( RESULTS_COUNT + 1 ))
    if (( RESULTS_COUNT > 2 )); then
      echo "$LOG_RESULTS"
      break;
    fi
    echo "we have $RESULTS_COUNT results - still waiting "
    sleep 60
  done

}


wait_for_pods_ready() {
  pods_selector="$@"
  while : ; do
    STATUS=$(oc get pods "$pods_selector" -o jsonpath="{.items[*].status.containerStatuses[*].ready}")
    PODS_NOT_READY=$(echo "$STATUS" | grep "false")

    if [ -z "$PODS_NOT_READY" ]; then
      echo "All pods are ready"
      break;
    fi
    sleep 5
  done
}

deploy_stress_with_configuration() {
  batch_size=$1
  write_msg_per_sec=$2
  write_replicas=$3

  deploy_stress "$write_replicas" "$write_msg_per_sec" "$batch_size"  0 0
  wait_for_pods_ready "-l app=write-stress"
  wait_for_pods_ready "-l app=query-stress"
}

deploy_loki_with_configuration() {
    loki_replications=$1
    deploy_loki_distributed_helm_chart "$loki_replications" "$s3_endpoint"
    wait_for_pods_ready "-l app.kubernetes.io/name=loki-distributed"
}

auto_deploy_loki() {

  # Initial benchmark deployment
  csv_filename="results/results_on_"$(date +"%m-%d-%y...%T")".csv"
  rm -f "$csv_filename"
  touch "$csv_filename"
  date
  echo "

  -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=
  ===>>>> results are also written to $csv_filename
  -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=


  ======>>> Performing initial loki benchmark deploy
  -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=

  "
  initial_deploy >/dev/null 2>&1

  ## re-deploy with specific configurations
  # per number of replications
  for ((loki_replications=loki_replicas_min;loki_replications<=loki_replicas_max;loki_replications++)); do
    date
    echo "

    ======>>> Deploying with loki replications $loki_replications
    -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=

    "
    deploy_loki_with_configuration "$loki_replications" >/dev/null 2>&1

    # per number of write replicas
    for ((write_replicas=write_replicas_min;write_replicas<=write_replicas_max;write_replicas+=1)); do

      # per size of write_batch
      for ((write_batch_size=write_batch_min;write_batch_size<=write_batch_max;write_batch_size+=write_batch_step)); do
        date
        echo "

        ======>>> Deploying with write batch size $write_batch_size
        -==--=-==--=-=-==--=-==-=--==--=-=-=-=-=-=-=-==--=-=-=-=-=-

        "

        deploy_stress_with_configuration "$write_batch_size" "$write_msg_per_sec" "$write_replicas" >/dev/null 2>&1
        date
        csv_line_pre="$replications,$write_batch_size,$write_msg_per_sec,$write_replicas,"
        collect_results "$csv_line_pre" "$csv_filename"
      done
    done
  done
}

AUTO_RUNNING="$(basename $(echo "$0" | sed 's/-//g'))"
if [[ "$AUTO_RUNNING" == "auto_execution.sh" ]]
then

  source ./contrib/deploy_functions.sh
  source ./deploy_loki_to_openshift.sh

  # fixed values
  warmup_wait=120
  deploy_minio=true
  s3_endpoint="s3://user:password@minio.loki.svc.cluster.local:9000/bucket"

  #default parameters
  write_batch_min=1
  write_batch_max=15
  write_batch_step=2
  write_msg_per_sec=2000
  write_replicas_min=1
  write_replicas_max=3
  loki_replicas_min=2
  loki_replicas_max=3

  for i in "$@"
  do
  case $i in
      --write_batch_min=*) write_batch_min="${i#*=}"; shift ;;
      --write_batch_max=*) write_batch_max="${i#*=}"; shift ;;
      --write_batch_step=*) write_batch_step="${i#*=}"; shift ;;
      --write_msg_per_sec=*) write_msg_per_sec="${i#*=}"; shift ;;
      --write_replicas_min=*) write_msg_per_sec="${i#*=}"; shift ;;
      --write_replicas_max=*) write_msg_per_sec="${i#*=}"; shift ;;
      --loki_replicas_min=*) replicas_min="${i#*=}"; shift ;;
      --loki_replicas_max=*) replicas_max="${i#*=}"; shift ;;
      -h|--help|*) auto_show_usage ;;
  esac
  done

  auto_deploy_loki "$@"
fi