## Introduction

This chart uses the [Helm Package Manager](https://helm.sh/) to setup:
- [Horovod](https://eng.uber.com/horovod/), a distributed framework for training models; and
- [Dask](https://dask.org/), a framework for distributed analytics at scale.

[Kolotoc](https://cs.wikipedia.org/wiki/Koloto%C4%8D) creates a [ring all-reduce](https://www.cs.fsu.edu/~xyuan/paper/09jpdc.pdf) network as Kubernetes statefulsets. Each worker node (statefulset) is of rank-0 to rank-n (where n is the total number of worker nodes). Each worker node is assigned to one or more [dask-workers](https://distributed.dask.org/en/latest/worker.html). The default number of dask-workers per worker node is given by the number of logical cores on each worker node. Kolotoc also creates a scheduler/master node outside of the computational ring as a Kubernetes deployment. The scheduler node is equipped with one [dask-scheduler](https://docs.dask.org/en/latest/scheduler-overview.html), [Tensorboard](https://www.tensorflow.org/guide/summaries_and_tensorboard), [Dask Bokeh](https://distributed.dask.org/en/latest/web.html), and [Jupyter Lab](https://jupyterlab.readthedocs.io/en/stable/).

<sub>* Kolotoc is based off the work done by [Cheyang](https://github.com/cheyang) </sub>

# Horovod

  Horovod is a distributed training framework for TensorFlow provided by Uber. The goal of Horovod is to make distributed training fast and easy to use vis-a-vis the ring-all-reduce algorithim.

# Dask

  Dask natively scales Python, providing advanced parallelism for analytics, enabling performance at scale for the tools you love. Dask uses existing Python APIs and data structures to make it easy to switch between Numpy, Pandas, Scikit-learn to their Dask-powered equivalents. Dask's schedulers scale to thousand-node clusters and its algorithms have been tested on some of the largest supercomputers in the world.

## Prerequisites

- Kubernetes cluster v1.8+
- jq 1.5-1

## Quick deployment on Google Cloud

  This repository contains `cluster.sh`, a limited utility script to automate the startup and teardown of cluster's running Kolotoc. Currently, `cluster.sh` only supports Google Cloud, and is only tested on Ubuntu 18.04.

### Start Cluster

  Assuming you have installed the [Google Cloud SDK](https://cloud.google.com/sdk/) and authenticated to the appropriate account, run `./cluster.sh --num-worker-nodes 2 --machine-type n1-standard-2` to start a two worker distributed ring.

  Type `./cluster.sh --help` for a list of available options and to customize your cluster setup.

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

### Interacting with the Cluster

  The utility script will output several web-addresses for:
  * Tensorboard
  * JupyterLab
  * Dask Web User Interface

Use your local browser to view each application. The default password for JupyterLab is `kolotoc`

You may also interact with the cluster by directly interacting with the scheduler node via the printed ```kubectl exec ... -it /bin/bash``` command.

Once inside the scheduler node, type run `goto 0` to navigate to worker node rank 0 or `goto n` to navigate to worker node rank n.

If each worker-node has been loaded with a Git repository (via a custom Dockerfile), you may run `update` to pull the latest repository on each worker node.

## Manual deployment
### Build Docker Image

The official Horovod Dockerfile is unsupported due to its incompatability with the Dask Dockerfile. Please use the Dockerfile provided in the base of this image as a starting image:

```
# mkdir horovod-docker
# wget -O horovod-docker/Dockerfile https://raw.githubusercontent.com/uber/horovod/master/Dockerfile
# docker build -t horovod:latest horovod-docker
```

## Prepare ssh keys

```
# Setup ssh key
export SSH_KEY_DIR=`mktemp -d`
cd $SSH_KEY_DIR
yes | ssh-keygen -N "" -f id_rsa
```

## Create the values.yaml

To run Kolotoc, create a `values.yaml`:

```
# cat << EOF > ~/values.yaml
---
projectName: ""

cuda:
  version: 10.0
  stubs: ""

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
  schedulerPort: ""
  bokehPort: ""
  jupyterPort: ""
  tensorboardPort: ""
  image:
    repository: ""
    tag: ""
    pullPolicy: IfNotPresent

worker:
  number: 1
  podManagementPolicy: Parallel
  image:
    repository: ""
    tag: ""
    pullPolicy: IfNotPresent
  resources: {}
    # limits:
    #   nvidia.com/gpu: 0
    # requests:
    #   nvidia.com/gpu: 0
  dask:
    number: 1
    gpu: 0
    threads: 1
    memory: 2GB
EOF
```

## Installing the Chart

To install the chart with the release name `mnist`:

```bash
$ helm install --values ~/values.yaml --name mnist stable/horovod
```
