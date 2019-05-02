#!/bin/bash
# DESCRIPTION
# Utility to start a Kubernetes cluster running Kolotoc
set -a
# set -vx # debug/verbose

# Note (1): Another implementation
# https://github.com/tensorflow/tensorflow/blob/master/tensorflow/tools/dist_test/scripts_allreduce/k8s_generate_yaml_lib.py
function usage {
  script_name=$0
  echo "Usage:"
  echo "  $script_name [--cluster-name cluster_name] [--num-worker-nodes num_of_workers]"
  echo "               [--service-file service_file] [--docker-repository docker_repository]"
  echo "               [--docker-tag docker_tag] [--node-gpus node_gpus]"
  echo "               [--node-type machine_type] [--scheduler-type]"
  echo "               [--dask-workers-per-node] [--dask-threads-per-worker]"
  echo "               [--node-disk-size machine_disk_size] [--help]"
  echo ""
  echo "  Parameters: "
  echo "    cluster_name:             name of the Kubernetes cluster. "
  echo "                              (default: kolotoc-cluster-uuid)"
  echo "    service_file:             the file path to the Google Cloud  "
  echo "                              service account credential. "
  echo "    num_worker_nodes:         number of worker nodes to launch."
  echo "    scheduler_type:           the google cloud machine type for scheduler. "
  echo "    node_type:                the google cloud machine type for workers. "
  echo "    node_gpus:                the number of attached gpus. (default: 0)"
  echo "    node_disk_size:           the size of each worker's disk space, given in "
  echo "                              gigabytes. (default: 50GB)"
  echo "    dask_workers_per_node:    the number of dask-workers running on each "
  echo "                              node. (default: number of logical cores)"
  echo "    dask_threads_per_worker:  the number of threads assigned to each "
  echo "                              dask-worker process. (default: 1) "
  echo ""
  echo "    help:               print setup."
}

# Image Config
MINIKUBE="" # minikube; whether to run in minikube or not, debug setting
MINIKUBE_DISK_SIZE="50GB"
PROJECT_NAME="${PROJECT_NAME:- 'kolotoc'}"
CLUSTER_NAME="$PROJECT_NAME-cluster-$(uuidgen | cut -c1-8)"
ZONE="us-east1-c"
MACHINE_TYPE="n1-standard-2"
MACHINE_GPU_TYPE="nvidia-tesla-k80"
MACHINE_GPUS="0"
MACHINE_DISK_SIZE="50"
NUM_WORKER_NODES="1"
ENTRY_POINT_NAME="scheduler" # Scheduler (entrypoint) config
WORKER_RING_NAME="worker-ring"
SCHEDULER_TYPE="n1-standard-1"
SCHEDULER_DISK_SIZE="50"
SCHEDULER_DISK_TYPE="pd-standard"
JUPYTER_NOTEBOOK_PASSWORD="${JUPYTER_NOTEBOOK_PASSWORD:-'kolotoc'}"
BUILD_KEY_LOCATION="/root/$PROJECT_NAME/inst/$PROJECT_NAME-build.key"
# Worker (ring-all-reduce) config
# We don't set --nprocs so that we can name the individaul workers and follow
# best-practices: https://github.com/dask/distributed/issues/2471
# "I recommend avoiding the --nprocs keyword."
# Each CPU on the node will get one dask-worker running one thread
# https://github.com/dask/dask/blob/master/docs/source/configuration.rst
DASK_WORKER_PROCESS="" # number of dask-workers per "worker" node, defaults to number of CPUs if blank
DASK_THREADS_PER_PROCESS="1"
DASK_WORKER_GPU="0"
DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES="100" # number of times a task can fail before killed by scheduler
DASK_DISTRIBUTED__WORKER__MEMORY__SPILL="0.50"
DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE="0.85"
DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE="1"

export TEMP_DIR=`mktemp -d`
declare -A AVAL_MACHINE_TYPES=(
  ["n1-standard-1"]="1 3.75e9" # minimum requirements
  ["n1-standard-2"]="2 7.5e9"
  ["n1-standard-4"]="4 15e9"
  ["n1-standard-8"]="8 30e9"
  ["n1-standard-16"]="16 60e9"
  ["n1-standard-32"]="32 120e9"
  ["n1-standard-64"]="64 240e9"
  ["n1-standard-96"]="96 360e9"
  ["n1-highmem-2"]="2 13e9"
  ["n1-highmem-4"]="4 26e9"
  ["n1-highmem-8"]="8 52e9"
  ["n1-highmem-16"]="16 104e9"
  ["n1-highmem-32"]="32 208e9"
  ["n1-highmem-64"]="64 416e9"
  ["n1-highmem-96"]="96 624e9"
  ["n1-highcpu-2"]="4 1.80e9"
  ["n1-highcpu-4"]="4 3.60e9"
  ["n1-highcpu-8"]="8 7.20e9"
  ["n1-highcpu-16"]="16 14.4e9"
  ["n1-highcpu-32"]="32 28.8e9"
  ["n1-highcpu-64"]="64 57.6e9"
  ["n1-highcpu-96"]="96 86.4e9"
  ["n1-ultramem-40"]="40 961e9"
  ["n1-ultramem-80"]="80 1922e9"
  ["n1-ultramem-160"]="96 3844e9"
  ["n1-megamem-96"]="96 1433.6e9")

setargs(){
  while [ "$1" != "" ]; do
    case "$1" in
      "--cluster-name")
        shift
        CLUSTER_NAME=$1
        ;;
      "--service-file")
        shift
        SERVICE_FILE=$1
        ;;
      "--num-worker-nodes")
        shift
        NUM_WORKER_NODES=$1
        ;;
      "--node-type")
        shift
        MACHINE_TYPE=$1
        ;;
      "--node-gpus")
        shift
        MACHINE_GPUS=$1
        ;;
      "--node-disk-size")
        shift
        MACHINE_DISK_SIZE=$1
        ;;
      "--dask-workers-per-node")
        shift
        DASK_WORKER_PROCESS=$1
        ;;
      "--dask-threads-per-worker")
        shift
        DASK_THREADS_PER_PROCESS=$1
        ;;
      "--scheduler-type")
        shift
        SCHEDULER_TYPE=$1
        ;;
      "--help")
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $key"
        usage
        exit 1
        ;;
    esac
    shift
  done
}
setargs $*

if [[ -z "$SERVICE_FILE" ]]; then
  echo "Please pass the location of the service file "
  echo "in the '--service-file' parameter"
  exit 1
fi

waitfor(){
  while [ -z $("$@") ]; do
    sleep 5
  done
  echo $("$@")
}

SERVICE_ACCOUNT="$(jq ".client_email" $SERVICE_FILE | tr -d '"')"
GREEN='\u001b[32;1m'
RED='\u001b[31;1m'
OFF='\033[0m'

if [ "$MACHINE_GPUS" -gt "0" ]; then
  if [ "$MACHINE_GPU_TYPE" == "" ]; then
    printf "$You must specify a GPU type when setting '--machine-gpus'. \
    Received $MACHINE_GPU_TYPE ${OFF}\n"
    exit 1
  fi
  ACCELERATOR="--accelerator type=$MACHINE_GPU_TYPE,count=$MACHINE_GPUS --zone=$ZONE"
fi

if [[ "$MINIKUBE" == "minikube" ]]; then
   printf "${GREEN}Setting up developer cluster in minikube... ${OFF}\n";
  if [[ $(minikube status | grep "host: ") == "host: Running" ]]; then
    kubectl delete --all pods,services,deployments,jobs,statefulsets,secrets,configmaps,daemonsets
  else
    minikube start --disk-size="$MINIKUBE_DISK_SIZE";
  fi
else
  MACHINE_CPU=$(echo "${AVAL_MACHINE_TYPES[$MACHINE_TYPE]}" | awk '{print $1}')
  MACHINE_MEMORY=$(echo "${AVAL_MACHINE_TYPES[$MACHINE_TYPE]}" | awk '{print $2}')

  if [[ -z "$MACHINE_CPU" || -z "$MACHINE_MEMORY" ]]; then
   printf "${RED}Could not find machine type $MACHINE_TYPE on GC! ${OFF}\n"
   exit 1
  fi

  CLUSTER="$(gcloud container clusters list --format="value(name)")"

  if [[ "$CLUSTER" == "$CLUSTER_NAME" ]]; then
    printf "${GREEN}Updating existing cluster $CLUSTER_NAME... ${OFF}\n"
    kubectl delete --all pods,services,deployments,jobs,statefulsets,secrets,configmaps,daemonsets
  else
    gcloud config set project "$GOOGLE_PROJECT_NAME"
    printf "${GREEN}Creating worker ring $CLUSTER_NAME on Google Cloud... ${OFF}\n"
    # Known issue where you can't modify the name of the default node-pool; so
    # start the cluster as a 'default-pool', but delete this node pool at the end
    # https://serverfault.com/questions/822787/create-google-container-
    # engine-cluster-without-default-node-pool
    gcloud container clusters \
    create "$CLUSTER_NAME" --no-user-output-enabled \
      --no-async \
      --service-account="$SERVICE_ACCOUNT" \
      --machine-type="f1-micro" \
      --zone="$ZONE"

    # Create the scheduler node: juypter notebook, bokeh dashboard, and all
    # other exposed services will sit here. This is the cluster's de-facto
    # entrypoint.
    printf "${GREEN}Adding a Dask scheduler node... ${OFF}\n"
    gcloud container node-pools \
    create "$CLUSTER_NAME-$ENTRY_POINT_NAME" --no-user-output-enabled \
      --cluster="$CLUSTER_NAME" \
      --service-account="$SERVICE_ACCOUNT" \
      --disk-type="$SCHEDULER_DISK_TYPE" \
      --disk-size="$SCHEDULER_DISK_SIZE" \
      --num-nodes="1" \
      --machine-type="$SCHEDULER_TYPE" \
      --zone="$ZONE"

    # Create a premptible worker ring: checkpoints are sent back to the
    # scheduler, and the scheduler controls the start/teardown of jobs
    gcloud container node-pools \
    create "$CLUSTER_NAME-$WORKER_RING_NAME" --no-user-output-enabled \
      --preemptible \
      --cluster="$CLUSTER_NAME" \
      --service-account="$SERVICE_ACCOUNT" \
      --num-nodes="$NUM_WORKER_NODES" \
      --machine-type="$MACHINE_TYPE" \
      --disk-size="$MACHINE_DISK_SIZE" ${ACCELERATOR:- --zone="$ZONE"}

    # Delete the default node pool
    gcloud container node-pools \
    delete "default-pool" --quiet --cluster "$CLUSTER_NAME" --zone="$ZONE"
  fi
fi

if [[ -z "$DASK_WORKER_PROCESS" ]]; then
  export DASK_WORKER_PROCESS=$MACHINE_CPU
fi

# Install NVIDIA drivers if using GPUs
if [ "$MACHINE_GPUS" -gt "0" ]; then
  printf "${GREEN}Applying $HOST_IMAGE_TYPE GPU device installer... ${OFF}\n"
  kubectl apply -f daemonset-preloaded.yaml
  kubectl label nodes $(kubectl get nodes -l \
    cloud.google.com/gke-nodepool="$CLUSTER_NAME-$WORKER_RING_NAME" \
    -o jsonpath="{.items[0].metadata.name}") hardware-type=NVIDIAGPU
fi

export DASK_WORKER_MEM=$(python -c "import os; \
  print(float(os.environ['MACHINE_MEMORY']) / \
  float(os.environ['DASK_WORKER_PROCESS']))")

export UPDATE_REPO_COMMAND="git fetch --all && \
  git reset --hard origin/master && \
  chmod 600 $BUILD_KEY_LOCATION && \
  git pull origin master"

ssh-keygen -qN "" -f $TEMP_DIR/id_rsa
chmod 400 $TEMP_DIR/id_rsa

cat << EOF > "$TEMP_DIR/configuration.yaml"
---
projectName: $PROJECT_NAME
image:
  repository: $DOCKER_REPOSITORY
  tag: $DOCKER_TAG

ssh:
  hostKey: |-
$(cat $TEMP_DIR/id_rsa | sed 's/^/    /g')
  hostKeyPub: |-
$(cat $TEMP_DIR/id_rsa.pub | sed 's/^/    /g')

useHostNetwork: $(if [ "$MINIKUBE" != "minikube" ]; then
  echo "true"; else echo "false"; fi)

scheduler:
  env:
    UPDATE_REPO_COMMAND: $UPDATE_REPO_COMMAND
    GIT_SSH_COMMAND: "ssh -p 22 -i $BUILD_KEY_LOCATION -o StrictHostKeyChecking=no"
    DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES: $DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES
    DASK_DISTRIBUTED__WORKER__MEMORY__SPILL: $DASK_DISTRIBUTED__WORKER__MEMORY__SPILL
    DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE: $DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE
    DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE: $DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE

worker:
  number: $NUM_WORKER_NODES
  podManagementPolicy: Parallel

  resources:
    limits:
      nvidia.com/gpu: $MACHINE_GPUS
    requests:
      nvidia.com/gpu: $MACHINE_GPUS

  dask:
    number: $DASK_WORKER_PROCESS
    gpu: $MACHINE_GPUS
    memory: $DASK_WORKER_MEM
    threads: $DASK_THREADS_PER_PROCESS

  env:
    GIT_SSH_COMMAND: "ssh -p 22 -i $BUILD_KEY_LOCATION -o StrictHostKeyChecking=no"
    DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES: $DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES
    DASK_DISTRIBUTED__WORKER__MEMORY__SPILL: $DASK_DISTRIBUTED__WORKER__MEMORY__SPILL
    DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE: $DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE
    DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE: $DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE
EOF

kubectl --namespace kube-system create serviceaccount tiller
kubectl create clusterrolebinding tiller \
  --clusterrole cluster-admin \
  --serviceaccount kube-system:tiller

# https://ryaneschinger.com/blog/using-google-container-registry-
# gcr-with-minikube/
if [[ "$MINIKUBE" == "minikube" ]]; then
  kubectl create secret docker-registry gcr-registry-key \
    --docker-server="$DOCKER_REPOSITORY" \
    --docker-username="_json_key" \
    --docker-password="$(cat $SERVICE_FILE)" \
    --docker-email="$AUTHOR_EMAIL"
  kubectl patch serviceaccount default \
    -p '{"imagePullSecrets": [{"name": "gcr-registry-key"}]}'
fi

rm -rf "$HOME/.helm";
helm init --service-account tiller --upgrade --wait;
if [[ "$CLUSTER" == "$CLUSTER_NAME" ]]; then
  helm del --purge "$CLUSTER_NAME"
fi

helm install . --name "$CLUSTER_NAME" --values "$TEMP_DIR/configuration.yaml"
# Note (1): This __MUST__ be done after helm install othwerise charts
# will fail to bind due to taints/tolerations.
kubectl taint nodes \
  -l "cloud.google.com/gke-nodepool=$CLUSTER_NAME-$ENTRY_POINT_NAME" \
  "node"="scheduler":"NoSchedule" --overwrite
kubectl taint nodes \
  -l "cloud.google.com/gke-nodepool=$CLUSTER_NAME-$WORKER_RING_NAME" \
  "node"="worker":"NoSchedule" --overwrite

printf "${GREEN}Waiting for helm chart to finish installation... ${OFF} \n"
export SCHEDULER_POD=$(waitfor kubectl get pods -l \
  role=scheduler -o jsonpath="{.items[0].metadata.name}")

# Expose Jupyter notebook service
kubectl expose pod "$SCHEDULER_POD" \
  --name="jupyter-lab" \
  --type="NodePort" \
  --port="8889" \
  --target-port="8889"

# Expose Dask-Bokeh notebook service
kubectl expose pod "$SCHEDULER_POD" \
  --name="dask-bokeh" \
  --type="NodePort" \
  --port="8687" \
  --target-port="8687"

# Expose Tensorboard service
kubectl expose pod "$SCHEDULER_POD" \
  --name="tensorboard" \
  --type="NodePort" \
  --port="5056" \
  --target-port="5056"

# Output to user console
printf "${GREEN}Jupyter notebook: https://127.0.0.1:8889 ${OFF}\n"
printf "${RED}Password: $JUPYTER_NOTEBOOK_PASSWORD ${OFF}\n"

printf "${GREEN}Bokeh dashboard: http://127.0.0.1:8687/status ${OFF}\n"
printf "${GREEN}Tensorboard: http://127.0.0.1:5056 ${OFF}\n"

printf "${GREEN}Port-forward: \
'kubectl port-forward $SCHEDULER_POD 8889 8687 \
5056' Use 'pkill kubectl -9' to kill. ${OFF}\n"

printf "${GREEN}Access entrypoint: \
'kubectl exec $SCHEDULER_POD -it bash' ${OFF}\n"

printf "${GREEN}Stream logs: \
'kubectl logs $SCHEDULER_POD -f' ${OFF}\n"

# printf "${GREEN}Copy trials/checkpoints: \
# 'kubectl cp default/$SCHEDULER_POD:/root/$PROJECT_NAME/checkpoints \
# $PROJECT_DIR/trials/$CLUSTER_NAME' ${OFF}\n"

echo "$JUPYTER_NOTEBOOK_PASSWORD" | xclip -sel clip
pkill kubectl -9 # kill any previous instances

# Copy checkpoints and meta-data back into local
# printf "Copying checkpoints in the background to \
#   $PROJECT_DIR/trials/$CLUSTER_NAME \n"
# (watch kubectl cp default/$SCHEDULER_POD:/root/deeptick/checkpoints \
#   $PROJECT_DIR/trials/$CLUSTER_NAME &>/dev/null &)

# Will fail on heavy loads
# $(waitfor kubectl port-forward $SCHEDULER_POD \
#   8889 8687 5056 &>/dev/null &)

kubectl exec "$SCHEDULER_POD" -it bash

# EOF
