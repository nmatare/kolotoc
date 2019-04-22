## Introduction

  This chart uses the [Helm Package Manager](https://helm.sh/) to setup:
  - [Horovod](https://eng.uber.com/horovod/), a distributed framework for training models; and
  - [Dask](https://dask.org/), a framework for distributed analytics at scale.

  [Kolotoc](https://cs.wikipedia.org/wiki/Koloto%C4%8D) creates a [ring all-reduce](https://www.cs.fsu.edu/~xyuan/paper/09jpdc.pdf) network as Kubernetes statefulsets. Each worker node (statefulset) is of rank-0 to rank-n (where n is the total number of worker nodes). Each worker node is assigned to one or more [dask-workers](https://distributed.dask.org/en/latest/worker.html). The default number of dask-workers per worker node is given by the number of logical cores per worker node. Kolotoc also creates a scheduler node outside of the computational ring as a Kubernetes deployment. The scheduler node serves as the entrypoint to the cluster and is equipped with one [dask-scheduler](https://docs.dask.org/en/latest/scheduler-overview.html), [Tensorboard](https://www.tensorflow.org/guide/summaries_and_tensorboard), [Dask Bokeh](https://distributed.dask.org/en/latest/web.html), and [Jupyter Lab](https://jupyterlab.readthedocs.io/en/stable/).


  <img src="https://user-images.githubusercontent.com/16640218/34506318-84d0c06c-efe0-11e7-8831-0425772ed8f2.png" width="150" height="150" align="left" style="margin-right: 20px;" >
  Horovod is a distributed training framework for TensorFlow, Keras, PyTorch, and MXNet. The goal of Horovod is to make distributed Deep Learning fast and easy to use.

  <br style = "line-height:6;"><br>

  <img src="https://dask.org/_images/dask_horizontal_white_no_pad.svg" width="150" height="100" align="left" style="margin-right: 20px;" >

  Dask natively scales Python, providing advanced parallelism for analytics, enabling performance at scale for the tools you love. Dask uses existing Python APIs and data structures to make it easy to switch between Numpy, Pandas, Scikit-learn to their Dask-powered equivalents. Dask's schedulers scale to thousand-node clusters and its algorithms have been tested on some of the largest supercomputers in the world.

## Prerequisites

- Kubernetes cluster v1.8+
- jq 1.5-1

## Quick deployment on Google Cloud

  This repository contains `cluster.sh`, a limited utility script to automate the startup and teardown of clusters running Kolotoc. Currently, `cluster.sh` only supports Google Cloud, Tensorflow, and is only tested on Ubuntu 18.04.

### Start Cluster

  Run `./cluster.sh --num-worker-nodes 2 --machine-type n1-standard-2` to start a two worker distributed ring. You will need to authenticate via the [Google Cloud SDK](https://cloud.google.com/sdk/) or supply a `service-file` parameter.  

  Type `./cluster.sh --help` for a list of available options:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster-name`  | name of the Kubernetes cluster  | `kolotoc-cluster-uuid` |
| `service-file`  | the file path to the Google Cloud  service account credential    | Required |
| `docker-repository`  | the location of the base Dockerfile image    | `nmatare/kolotoc` |
| `docker-tag`  | the tag of the base Dockerfile image    | `latest` |
| `num-worker-nodes`  | number of worker nodes to launch    | Required |
| `node-type`  | the google cloud machine type for worker nodes    | Required |
| `scheduler-type`  | the google cloud machine type for the scheduler    | `n1-standard-1` |
| `node-gpus`  | the number of attached gpus per worker node    | `0` |
| `node-disk-size`  | the size of each worker's disk space given in gigabytes    | `50GB` |
| `dask-workers-per-node`  | the number of dask-workers running on each node | number of logical cores per node |
| `dask-threads-per-worker`  | the number of threads assigned to each dask-worker process    | `1` |

### Interacting with the Cluster

  The utility script will output several web-addresses for:
  * Tensorboard
  * JupyterLab
  * Dask Web User Interface

Use your local browser to view each application. The default password for JupyterLab is `kolotoc`

You may also interact with the cluster via the printed ```kubectl exec ... -it /bin/bash``` command. Running the command will connect you to the scheduler node.

Once inside the scheduler node, type run `goto 0` to navigate to worker node rank 0 or `goto n` to navigate to worker node rank n. Where n is the total number of available workers.

If each worker-node has been loaded with a Git repository (via a custom Dockerfile), run `update` (no parameters) to pull the latest repository on each worker node.

## Manual deployment
### Build Docker Image

The official Horovod Dockerfile is unsupported due to its incompatability with the Dask Dockerfile. Please use the Dockerfile provided in the base of this image as a starting point:

```bash
mkdir kolotoc-docker
wget -O kolotoc-docker/Dockerfile https://raw.githubusercontent.com/nmatare/kolotoc/master/Dockerfile?token=AD7C53PTEVX447DJOGJEFVC4Y5CGW
docker build -t kolotoc:latest kolotoc-docker
```

## Prepare ssh keys

```bash
# Setup ssh key
export SSH_KEY_DIR=`mktemp -d`
cd $SSH_KEY_DIR
yes | ssh-keygen -N "" -f id_rsa
```

## Create the values.yaml

To run Kolotoc, create a `values.yaml`

```yaml
projectName: "kolotoc"
image:
  repository: "nmatare/kolotoc"
  tag: "latest"
  pullPolicy: IfNotPresent

cuda:
  stubs: "/usr/local/cuda/targets/x86_64-linux/lib/stubs"

ssh:
  port: 3222
  hostKey: |-
    #  -----BEGIN RSA PRIVATE KEY-----
    #  YourPrivateKey
    #  -----END RSA PRIVATE KEY-----
  hostKeyPub: |-
    #  ssh-rsa YourPublicKey

useHostNetwork: true
useHostPID: false

scheduler:
  schedulerPort: 8686
  bokehPort: 8687
  jupyterPort: 8889
  tensorboardPort: 5056

worker:
  number: 1
  podManagementPolicy: Parallel
  resources: {}
    # limits:
    #   nvidia.com/gpu: 0
    # requests:
    #   nvidia.com/gpu: 0
  dask:
    number: 1
    gpu: 0
    threads: 1
    memory: "2GB"
```

## Configuration
The below table lists the configurable parameters for the `values.yaml` file and
the respective default values.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `projectName`  | Identifying attribute    | `kolotoc` |
| `image.repository`  | Dockerfile repository    | `nmatare/kolotoc` |
| `image.tag`  | Dockerfile tag    | `latest` |
| `image.pullPolicy`  |  Kubernetes 'pull policy'   | `IfNotPresent` |
| `cuda.stubs` | Location to CUDA stubs | `/usr/local/cuda/targets/x86_64-linux/lib/stubs` |
| `ssh.port` | The SSH port for worker-node communication | `3222` |
| `ssh.hostKey`  | SSH RSA private key    | Required |
| `ssh.hostKeyPub` | SSH RSA public key | Required |
| `useHostNetwork`  | Host network    | `true` |
| `useHostPID` | Host PID | `false` |
| `scheduler.schedulerPort`  | The port to the Dask scheduler    | `8686` |
| `scheduler.bokehPort` | Dask Web UI Port (exposed) | `8687` |
| `scheduler.jupyterPort`  | Jupyter Lab Port (exposed) | `8889` |
| `scheduler.tensorboardPort` | Tensorboard Port (exposed) | `5056` |
| `scheduler.env` | Scheduler environment variables | `{}` |
| `worker.number`  | The number of worker-nodes    | `1` |
| `worker.env` | Worker environment variables | `{}` |
| `worker.podManagementPolicy`  | Worker-node policy    | `Parallel` |
| `worker.resources.limits.nvidia.com/gpu`  | Number of total attached GPUs   | `false` |
| `worker.resources.requests.nvidia.com/gpu`  | Number of requested attached GPUs    | `false` |
| `worker.dask.number`  | The number of dask-workers per worker-node    | `1` |
| `worker.dask.gpu`  | The number of GPUs dask-workers can access    | `0` |
| `worker.dask.threads`  | The number of threads per dask-worker    | `1` |
| `worker.dask.memory`  | The amount of memory available to each dask-worker   | `2GB` |

## Installing the Chart

```bash
$ helm install --values ~/values.yaml nmatare/kolotoc
```

## Misc

This chart is based off [stable/horovod](https://github.com/helm/charts/tree/master/stable/horovod)
created by cheyang.

What's a kolotoc?
A [czech carousel](https://sk.wikipedia.org/wiki/Koloto%C4%8D) not unlike the Russian horovod dance.
