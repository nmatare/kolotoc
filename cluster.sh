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
  echo "  $script_name [--cluster-name cluster_name] "
  echo "               [--num-carriers num_carrier_nodes]"
  echo "               [--carrier-type carrier_type]"

  echo "               [--num-towers num_tower_nodes]"
  echo "               [--tower-type tower_machine_type]"
  echo "               [--gpus-per-tower gpus_per_tower]"
  echo "               [--gpu-type gpu_type]"

  echo "               [--help]"

  echo "  Parameters: "
  echo "  cluster_name:       name of the Kubernetes cluster. "
  echo "                      (default: kolotoc-cluster-uuid)"
  echo "  num_carrier_nodes:  number of carriers (nodes with dask-workers) to launch."
  echo "  carrier_type:       the machine type used by carriers (given by Google Cloud Compute). "

  echo "  num_tower_nodes:    the number of ring-all-reduce machine nodes to launch. "
  echo "  num-dask-workers:   optional control over the number of dask-workers per carrier node"
  echo "  gpus_per_tower:     the number gpus to attach to each tower. (default: 0)"
  echo "  gpu_type:           the type of gpu to attach to each tower. (default: nvidia-tesla-k80)"
  echo "  help:               print setup. "
}

# Image Config
PROJECT_NAME="${PROJECT_NAME:-kolotoc}"
CLUSTER_NAME="$PROJECT_NAME-cluster-$(uuidgen | cut -c1-8)"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-nmatare/kolotoc}"
DOCKER_TAG="${DOCKER_TAG:-latest}"

# Scheduler config
SCHEDULER_NAME="scheduler" # Scheduler (entrypoint) config
SCHEDULER_MACHINE_TYPE="n1-standard-2"
SCHEDULER_DISK_SIZE=50
SCHEDULER_DISK_TYPE="pd-standard"
JUPYTER_NOTEBOOK_PASSWORD="${JUPYTER_NOTEBOOK_PASSWORD:-kolotoc}"
BUILD_KEY_LOCATION="/root/$PROJECT_NAME/inst/$PROJECT_NAME-build.key"

# Carrier config
CARRIER_NAME="carrier"
CARRIER_MACHINE_TYPE="n1-highcpu-2"
CARRIER_DISK_SIZE=50
NUM_CARRIER_NODES=1

# Tower config
TOWER_NAME="tower"
TOWER_MACHINE_TYPE="n1-highmem-2"
TOWER_GPU_TYPE="nvidia-tesla-k80"
ZONE="us-east4-a"
# k80/t4 -  us-east1-d
# p100 - us-east1-b
# p4   - us-east4-a
TOWER_DISK_SIZE=50
TOWER_MACHINE_GPUS=0
NUM_TOWER_NODES=1

# Dask config
NUM_DASK_WORKERS=""
DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES=100
DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE=1  # use kubernetes to manage
DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL=100
DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE="0.90"
DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=300
DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=420
# https://github.com/dask/dask/blob/master/docs/source/configuration.rst
# unlike spill/pause/target, terminate is set on the nanny and, currently,
# there is no easy way to adjust parameters on the nanny. We hard-code this 
# here, and expect the user to adjust the other parameters via direct calls
# to the workers. This is likewise true for `timeout`, which is set in the 

export TEMP_DIR=`mktemp -d`

setargs(){
  while [ "$1" != "" ]; do
    case "$1" in
      "--cluster-name")
        shift
        CLUSTER_NAME=$1
        ;;
      "--num-carriers")
        shift
        NUM_CARRIER_NODES=$1
        ;;
      "--carrier-type")
        shift
        CARRIER_MACHINE_TYPE=$1
        ;;
      "--num-towers")
        shift
        NUM_TOWER_NODES=$1
        ;;
      "--tower-type")
        shift
        TOWER_MACHINE_TYPE=$1
        ;;        
      "--gpus-per-tower")
        shift
        TOWER_MACHINE_GPUS=$1
        ;;
      "--gpu-type")
        shift
        TOWER_GPU_TYPE=$1
        ;;
      "--num-dask-workers")
        shift
        NUM_DASK_WORKERS=$1
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

waitfor(){
  while [ -z $("$@") ]; do
    sleep 5
  done
  echo $("$@")
}

GREEN='\u001b[32;1m'
RED='\u001b[31;1m'
OFF='\033[0m'

declare -A AVAL_MACHINE_TYPES=(
  ["n1-standard-1"]="1 3.75" # minimum requirements
  ["n1-standard-2"]="2 7.5"
  ["n1-standard-4"]="4 15"
  ["n1-standard-8"]="8 30"
  ["n1-standard-16"]="16 60"
  ["n1-standard-32"]="32 120"
  ["n1-standard-64"]="64 240"
  ["n1-standard-96"]="96 360"
  ["n1-highmem-2"]="2 13"
  ["n1-highmem-4"]="4 26"
  ["n1-highmem-8"]="8 52"
  ["n1-highmem-16"]="16 104"
  ["n1-highmem-32"]="32 208"
  ["n1-highmem-64"]="64 416"
  ["n1-highmem-96"]="96 624"
  ["n1-highcpu-2"]="4 1.80"
  ["n1-highcpu-4"]="4 3.60"
  ["n1-highcpu-8"]="8 7.20"
  ["n1-highcpu-16"]="16 14.4"
  ["n1-highcpu-32"]="32 28.8"
  ["n1-highcpu-64"]="64 57.6"
  ["n1-highcpu-96"]="96 86.4"
  ["n1-ultramem-40"]="40 961"
  ["n1-ultramem-80"]="80 1922"
  ["n1-ultramem-160"]="96 3844"
  ["n1-megamem-96"]="96 1433.6")


TOWER_MACHINE_CPU=$(echo "${AVAL_MACHINE_TYPES[$TOWER_MACHINE_TYPE]}" | awk '{print $1}')
TOWER_MACHINE_MEMORY=$(echo "${AVAL_MACHINE_TYPES[$TOWER_MACHINE_TYPE]}" | awk '{print $2}')

CARRIER_MACHINE_CPU=$(echo "${AVAL_MACHINE_TYPES[$CARRIER_MACHINE_TYPE]}" | awk '{print $1}')
CARRIER_MACHINE_MEMORY=$(echo "${AVAL_MACHINE_TYPES[$CARRIER_MACHINE_TYPE]}" | awk '{print $2}')

if [[ "$TOWER_MACHINE_GPUS" -gt "0" ]]; then
  if [[ "$TOWER_GPU_TYPE" == "" ]]; then
    printf "$You must specify a GPU type when setting '--num-gpus'. \
    Received $TOWER_GPU_TYPE ${OFF}\n"
    exit 1
  fi
  ACCELERATOR="--accelerator type=$TOWER_GPU_TYPE,count=$TOWER_MACHINE_GPUS --zone=$ZONE"
fi

CLUSTER="$(gcloud container clusters list --format="value(name)")"

if [[ "$CLUSTER" == "$CLUSTER_NAME" ]]; then
  printf "${GREEN}Updating existing cluster $CLUSTER_NAME... ${OFF}\n"
  kubectl delete --all pods,services,deployments,jobs,statefulsets,secrets,configmaps,daemonsets
else

  if [[ -z "$CARRIER_MACHINE_CPU" || -z "$CARRIER_MACHINE_MEMORY" ]]; then
    printf "${RED}Could not find machine type $CARRIER_MACHINE_TYPE on GC!${OFF}\n"
    exit 1
  fi

  gcloud config set project "$GOOGLE_PROJECT_NAME"
  printf "${GREEN}Creating cluster $CLUSTER_NAME on Google Cloud... ${OFF}\n"
  # Known issue where you can't modify the name of the default node-pool; so
  # start the cluster as a 'default-pool', but delete this node pool at the end
  # https://serverfault.com/questions/822787/create-google-container-
  # engine-cluster-without-default-node-pool
  gcloud container clusters \
  create "$CLUSTER_NAME" --no-user-output-enabled \
    --no-async \
    --machine-type="f1-micro" \
    --zone="$ZONE"

  # Create the scheduler node: juypter notebook, bokeh dashboard, and all
  # other exposed services will sit here. This is the cluster's de-facto
  # entrypoint.
  printf "${GREEN}Creating a Scheduler node (dask-scheduler node)... ${OFF}\n"
  gcloud container node-pools \
  create "$CLUSTER_NAME-$SCHEDULER_NAME" --no-user-output-enabled \
    --cluster="$CLUSTER_NAME" \
    --disk-size="$SCHEDULER_DISK_SIZE" \
    --num-nodes="1" \
    --machine-type="$SCHEDULER_MACHINE_TYPE" \
    --zone="$ZONE" 

  # To avoid restrictions GPU/CPU ratio limitations (on both GCS and AWS),
  # we seperate the machine-nodes the cards sit on and create "Towers"
  if [[ "$NUM_TOWER_NODES" -gt "0" ]]; then
    printf "${GREEN}Creating Tower nodes (ring-all-reduce network)... ${OFF}\n"
    gcloud container node-pools \
    create "$CLUSTER_NAME-$TOWER_NAME" --no-user-output-enabled \
      --preemptible \
      --cluster="$CLUSTER_NAME" \
      --num-nodes="$NUM_TOWER_NODES" \
      --machine-type="$TOWER_MACHINE_TYPE" \
      --disk-size="$TOWER_DISK_SIZE" ${ACCELERATOR:- --zone="$ZONE"}
  fi

  # We add 'carrier' machine nodes that serve as nodes filled with dask-workers
  printf "${GREEN}Creating Carrier nodes (dask-worker network)... ${OFF}\n"
  gcloud container node-pools \
  create "$CLUSTER_NAME-$CARRIER_NAME" --no-user-output-enabled \
    --preemptible \
    --cluster="$CLUSTER_NAME" \
    --disk-size="$CARRIER_DISK_SIZE" \
    --num-nodes="$NUM_CARRIER_NODES" \
    --machine-type="$CARRIER_MACHINE_TYPE" \
    --zone="$ZONE"

  # Delete the default node pool
  gcloud container node-pools \
  delete "default-pool" --quiet --cluster "$CLUSTER_NAME" --zone="$ZONE"
fi

# Install NVIDIA drivers if using GPUs
if [[ "$TOWER_MACHINE_GPUS" -gt "0" ]]; then
  printf "${GREEN}Applying GPU device installer... ${OFF}\n"
  kubectl apply -f daemonset-preloaded.yaml
  kubectl label nodes $(kubectl get nodes -l \
    cloud.google.com/gke-nodepool="$CLUSTER_NAME-$TOWER_NAME" \
    -o jsonpath="{.items[0].metadata.name}") hardware-type=NVIDIAGPU  --overwrite
fi

ssh-keygen -qN "" -f $TEMP_DIR/id_rsa
chmod 400 $TEMP_DIR/id_rsa

cat << EOF > "$TEMP_DIR/configuration.yaml"
---
projectName: $PROJECT_NAME
image:
  repository: $DOCKER_REPOSITORY
  tag: $DOCKER_TAG

ssh:
  port: 3222
  hostKey: |-
$(cat $TEMP_DIR/id_rsa | sed 's/^/    /g')
  hostKeyPub: |-
$(cat $TEMP_DIR/id_rsa.pub | sed 's/^/    /g')

carrier:
  number: $NUM_CARRIER_NODES
  workers: $(if [[ ! -z "$NUM_DASK_WORKERS" ]]; then 
    echo "$NUM_DASK_WORKERS"; else echo "$CARRIER_MACHINE_CPU" ; fi)

tower:
  number: $NUM_TOWER_NODES
  gpus: $(if [[ "$TOWER_MACHINE_GPUS" -gt "0" ]]; then 
    echo "$TOWER_MACHINE_GPUS"; else echo "0"; fi)

env:
  BUILD_KEY_LOCATION: $BUILD_KEY_LOCATION
  GIT_SSH_COMMAND: "ssh -p 22 -i $BUILD_KEY_LOCATION -o StrictHostKeyChecking=no"
  DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES: $DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES	
  DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT: $DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT
  DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP: $DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP
  DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE: $DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE
  DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE: $DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE
  DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL: $DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL

EOF

kubectl --namespace kube-system create serviceaccount tiller
kubectl create clusterrolebinding tiller \
  --clusterrole cluster-admin \
  --serviceaccount kube-system:tiller

rm -rf "$HOME/.helm";
if [[ "$CLUSTER" == "$CLUSTER_NAME" ]]; then
  helm del --purge "$CLUSTER_NAME"
fi
helm init --service-account tiller --upgrade --wait;

kubectl taint nodes \
  -l "cloud.google.com/gke-nodepool=$CLUSTER_NAME-$SCHEDULER_NAME" \
  "node"="scheduler":"NoSchedule" --overwrite

kubectl taint nodes \
  -l "cloud.google.com/gke-nodepool=$CLUSTER_NAME-$TOWER_NAME" \
  "node"="tower":"NoSchedule" --overwrite

kubectl taint nodes \
  -l "cloud.google.com/gke-nodepool=$CLUSTER_NAME-$CARRIER_NAME" \
  "node"="carrier":"NoSchedule" --overwrite

helm install . --name "$CLUSTER_NAME" --values "$TEMP_DIR/configuration.yaml"

printf "${GREEN}Waiting for helm chart to finish installation... ${OFF} \n"
export SCHEDULER_POD=$(waitfor kubectl get pods -l \
  role=scheduler -o jsonpath="{.items[0].metadata.name}")

# Expose Jupyter notebook service
kubectl expose pod "$SCHEDULER_POD" \
  --name="jupyter-lab" \
  --type="NodePort" \
  --port="8889" \
  --target-port="8889"

# Expose Dask notebook service
kubectl expose pod "$SCHEDULER_POD" \
  --name="dashboard" \
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
echo ""
printf "${GREEN}Jupyter notebook: https://127.0.0.1:8889 ${OFF}\n"
printf "${RED}Password: $JUPYTER_NOTEBOOK_PASSWORD ${OFF}\n"

printf "${GREEN}Dask dashboard: http://127.0.0.1:8687/status ${OFF}\n"
printf "${GREEN}Tensorboard: http://127.0.0.1:5056 ${OFF}\n"
echo ""

printf "${GREEN}Port-forward: \
'kubectl port-forward $SCHEDULER_POD 8889 8686 8687 5056' \
Use 'pkill kubectl -9' to kill. ${OFF}\n"
printf "${GREEN}Access entrypoint: \
'kubectl exec $SCHEDULER_POD -it /bin/bash' ${OFF}\n"
echo ""

printf "${GREEN}Stream logs: \
'kubectl logs $SCHEDULER_POD -f' ${OFF}\n"
printf "${GREEN}Copy trials/checkpoints: \
'kubectl cp default/$SCHEDULER_POD:/root/$PROJECT_NAME/checkpoints \
$PROJECT_DIR/trials/$CLUSTER_NAME' ${OFF}\n"
echo ""

printf "${GREEN}Switch to master branch across all towers: \
'repo checkout master' ${OFF}\n"
printf "${GREEN}Update the repository across all towers: \
'repo update master' ${OFF}\n"
printf "${GREEN}Go to tower zero (rank-zero): \
'goto tower 0' ${OFF}\n"
printf "${GREEN}Go to carrier zero: \
'goto carrier 0' ${OFF}\n"
echo ""

kubectl exec $SCHEDULER_POD -it /bin/bash

# EOF
