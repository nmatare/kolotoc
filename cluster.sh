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

  echo "               [--num-nodes num_nodes]"
  echo "               [--machine-type machine_type]"
  echo "               [--num-gpus-per-node num_gpus]"
  echo "               [--gpu-type gpu_type]"

  echo "               [--num-rings-per-node num_rings]"
  echo "               [--help]"

  echo "  Parameters: "
  echo "  cluster_name:       the name of the Kubernetes cluster. (default: kolotoc-cluster-uuid)"
  echo "  num_rings_per_node: the number of pods linked together in a ring-all-reduce network, per node (default: 1)"
  echo "  machine_type:       the desired machine type (default: n1-highmem-2)"
  echo "  num_nodes:          the number of total machine nodes (must manually scale with the number of pods) (default: 1)"
  echo "  num_gpus_per_node:  the number of available gpus per machine(node) (default: 0)"
  echo "  gpu_type:           the type of gpu to attach to each pod. (default: nvidia-tesla-k80)"
  echo "  help:               print setup. "
}

# Image Config
PROJECT_NAME="${PROJECT_NAME:-kolotoc}"
CLUSTER_NAME="$PROJECT_NAME-cluster-$(uuidgen | cut -c1-8)"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-nmatare/kolotoc}"
DOCKER_TAG="${DOCKER_TAG:-latest}"

JUPYTER_NOTEBOOK_PASSWORD="${JUPYTER_NOTEBOOK_PASSWORD:-kolotoc}"
BUILD_KEY_LOCATION="/root/$PROJECT_NAME/inst/$PROJECT_NAME-build.key"

NUM_NODES=1
MACHINE_TYPE="n1-standard-2"
GPU_TYPE="nvidia-tesla-k80"
ZONE="us-east1-d"
# k80/t4 -  us-east1-d
# p100 - us-east1-b
# p4   - us-east4-a
MACHINE_DISK_SIZE=300
MACHINE_GPUS=0
NUM_RANKS_PER_NODE=1
GOOGLE_CLOUD_NVIDIA_DEVICE_DRIVER=https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded.yaml

# Dask config
NUM_DASK_WORKERS=""
DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES=100
DASK_DISTRIBUTED__WORKER__DAEMON=False
DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE=1  # use kubernetes to manage
DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL=100
DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE=0.90
DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=300
DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=420
# dask.config.get('distributed.worker')
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
      "--num-rings-per-node")
        shift
        NUM_RANKS_PER_NODE=$1
        ;;
      "--num-nodes")
        shift
        NUM_NODES=$1
        ;;
      "--machine-type")
        shift
        MACHINE_TYPE=$1
        ;;        
      "--num-gpus-per-node")
        shift
        MACHINE_GPUS=$1
        ;;
      "--gpu-type")
        shift
        GPU_TYPE=$1
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
  ["custom-8-15360"]="8 15"
  ["custom-8-20480"]="8 20"
  ["custom-8-25600"]="8 25"
  ["custom-4-25600"]="4 30"
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


MACHINE_CPU=$(echo "${AVAL_MACHINE_TYPES[${MACHINE_TYPE}]}" | awk '{print $1}')
MACHINE_MEMORY=$(echo "${AVAL_MACHINE_TYPES[${MACHINE_TYPE}]}" | awk '{print $2}')


if [[ "${MACHINE_GPUS}" -gt "0" ]]; then
  if [[ "${GPU_TYPE}" == "" ]]; then
    printf "${RED}You must specify a GPU type when setting '--num-gpus'. \
    Received ${GPU_TYPE} ${OFF}\n"
    exit 1
  fi

  case "${GPU_TYPE}" in
    "nvidia-tesla-k80")
      shift
      ZONE="us-west1-b"  # us-west1-b
      ;;
    "nvidia-tesla-t4")
      shift
      ZONE="us-east1-d"
      ;;
    "nvidia-tesla-p4")
      shift
      ZONE="us-east4-a"
      ;;
    "nvidia-tesla-p100")
      shift
      ZONE="us-west1-b"
      ;;
    "nvidia-tesla-v100")
      shift
      ZONE="us-west1-b"
      ;;
  esac

  printf "${GREEN}Migrating cluster to zone '${ZONE}' to accomadate GPU locations... ${OFF}\n"

  ACCELERATOR="--accelerator type=${GPU_TYPE},count=${MACHINE_GPUS} --zone=${ZONE}"
fi

CLUSTER="$(gcloud container clusters list --format="value(name)")"

if [[ "${CLUSTER}" == "${CLUSTER_NAME}" ]]; then
  printf "${GREEN}Updating existing cluster ${CLUSTER_NAME}... ${OFF}\n"
  kubectl delete --all pods,services,deployments,jobs,statefulsets,secrets,configmaps,daemonsets
else

  gcloud config set project "${GOOGLE_PROJECT_NAME}"
  gcloud auth activate-service-account --key-file "${SERVICE_FILE}"
  gcloud auth configure-docker

  printf "${GREEN}Creating cluster ${CLUSTER_NAME} on Google Cloud... ${OFF}\n"

    # --preemptible \
  gcloud container clusters \
  create "$CLUSTER_NAME" --no-user-output-enabled \
    --no-async \
    --num-nodes="${NUM_NODES}" \
    --machine-type="${MACHINE_TYPE}" \
    --disk-size="${MACHINE_DISK_SIZE}" \
    --zone="${ZONE}" \
    --disk-size="${MACHINE_DISK_SIZE}" ${ACCELERATOR:- --zone="${ZONE}"}
fi

gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${ZONE}"

# Install NVIDIA drivers if using GPUs
if [[ "${MACHINE_GPUS}" -gt "0" ]]; then
  printf "${GREEN}Applying GPU device installer... ${OFF}\n"
  kubectl apply -f "${GOOGLE_CLOUD_NVIDIA_DEVICE_DRIVER}"
  kubectl label nodes $(kubectl get nodes -l \
    cloud.google.com/gke-nodepool=default-pool \
    -o jsonpath="{.items[0].metadata.name}") hardware-type=NVIDIAGPU  --overwrite

fi

ssh-keygen -qN "" -f ${TEMP_DIR}/id_rsa
chmod 400 ${TEMP_DIR}/id_rsa

# Keeping the "one process per container" best practice in mind, we limit
# one dask worker (process) per rank(pod).
# "The Docker developers advocate the philosophy of running a
# single __logical__ service per container."

cat << EOF > "${TEMP_DIR}/configuration.yaml"
---
projectName: ${PROJECT_NAME}
image:
  repository: ${DOCKER_REPOSITORY}
  tag: ${DOCKER_TAG}

ssh:
  port: 3222
  hostKey: |-
$(cat ${TEMP_DIR}/id_rsa | sed 's/^/    /g')
  hostKeyPub: |-
$(cat ${TEMP_DIR}/id_rsa.pub | sed 's/^/    /g')

ring:
  number: $((${NUM_RANKS_PER_NODE} * ${NUM_NODES}))
  workers: 1
  gpus: $(if [[ "${MACHINE_GPUS}" -gt "0" ]]; then 
    echo "${MACHINE_GPUS}"; else echo "0"; fi)

env:
  BUILD_KEY_LOCATION: ${BUILD_KEY_LOCATION}
  GIT_SSH_COMMAND: "ssh -p 22 -i ${BUILD_KEY_LOCATION} -o StrictHostKeyChecking=no"
  DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES: ${DASK_DISTRIBUTED__SCHEDULER__ALLOWED_FAILURES} 
  DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT: ${DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT}
  DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP: ${DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP}
  DASK_DISTRIBUTED__WORKER__DAEMON: ${DASK_DISTRIBUTED__WORKER__DAEMON}
  DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE: ${DASK_DISTRIBUTED__WORKER__MEMORY__PAUSE}
  DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE: ${DASK_DISTRIBUTED__WORKER__MEMORY__TERMINATE}
  DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL: ${DASK_DISTRIBUTED__WORKER__PROFILE_INTERVAL}
EOF

if [[ "${CLUSTER}" == "${CLUSTER_NAME}" ]]; then
  helm uninstall "${CLUSTER_NAME}"
else
  # escape `metrics.k8s.io/v1beta1: the server is currently unable to handle the request` bug
  sleep 120
fi

helm install "${CLUSTER_NAME}" . --values "${TEMP_DIR}/configuration.yaml"

printf "${GREEN}Waiting for helm chart to finish installation... ${OFF} \n"
export SCHEDULER_POD=$(waitfor kubectl get pods -l \
  role=scheduler -o jsonpath="{.items[0].metadata.name}")

# Output to user console
echo ""
printf "${GREEN}Jupyter notebook: https://127.0.0.1:8889 ${OFF}\n"
printf "${RED}Password: ${JUPYTER_NOTEBOOK_PASSWORD} ${OFF}\n"

printf "${GREEN}Dask dashboard: http://127.0.0.1:8687/status ${OFF}\n"
printf "${GREEN}Tensorboard: http://127.0.0.1:5056 ${OFF}\n"
echo ""

printf "${GREEN}Port-forward from the scheduler: \
'kubectl port-forward ${SCHEDULER_POD} 8889 8686 8687' \
Use 'pkill kubectl -9' to kill. ${OFF}\n"

printf "${GREEN}Port-forward from rank-0: \
'kubectl port-forward ${CLUSTER_NAME}-kolotoc-0 5056' ${OFF}\n"

printf "${GREEN}Access entrypoint: \
'kubectl exec ${SCHEDULER_POD} -it /bin/bash' ${OFF}\n"
echo ""

printf "${GREEN}Stream logs: \
'kubectl logs ${SCHEDULER_POD} -f' ${OFF}\n"

printf "${GREEN}Copy trials/checkpoints: \
'kubectl cp default/${CLUSTER_NAME}-kolotoc-0:/root/$PROJECT_NAME/checkpoints \
${PROJECT_DIR}/trials/${CLUSTER_NAME}' ${OFF}\n"
echo ""

printf "${GREEN}Switch to master branch across all ranks(pods): \
'repo checkout master' ${OFF}\n"
printf "${GREEN}Update the repository across all ranks(pods): \
'repo update master' ${OFF}\n"
printf "${GREEN}Go to ring zero (rank-zero): \
'goto ring 0' ${OFF}\n"
echo ""

kubectl exec "${SCHEDULER_POD}" -it /bin/bash

# EOF
