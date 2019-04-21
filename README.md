## Introduction

This chart uses the Helm Package Manager to setup:
- [Horovod](https://eng.uber.com/horovod/), a distributed framework for training models; and
- [Dask](https://dask.org/), a framework for distributed analytics at scale.

[Kolotoc](https://cs.wikipedia.org/wiki/Koloto%C4%8D) creates a [ring all-reduce](https://www.cs.fsu.edu/~xyuan/paper/09jpdc.pdf) network as Kubernetes statefulsets. Each worker node (statefulset) is of rank-0 to rank-n (where n is the total number of worker nodes). Each worker node is assigned to one or more [dask-workers](https://distributed.dask.org/en/latest/worker.html). The default number of dask-workers per worker node is given by the number of logical cores on each worker node. Kolotoc also creates a scheduler/master node outside of the computational ring as a Kubernetes deployment. The scheduler node is equipped with one [dask-scheduler](https://docs.dask.org/en/latest/scheduler-overview.html), [Tensorboard](https://www.tensorflow.org/guide/summaries_and_tensorboard), [Dask Bokeh](https://distributed.dask.org/en/latest/web.html), and [Jupyter Lab](https://jupyterlab.readthedocs.io/en/stable/).

This chart is based off the work done by [cheyang](https://github.com/helm/charts/tree/master/stable/horovod)

# Horovod

  Horovod is a distributed training framework for TensorFlow provided by Uber. The goal of Horovod is to make distributed training fast and easy to use vis-a-vis the ring-all-reduce algorithim.

# Dask 

  Dask natively scales Python, providing advanced parallelism for analytics, enabling performance at scale for the tools you love. Dask uses existing Python APIs and data structures to make it easy to switch between Numpy, Pandas, Scikit-learn to their Dask-powered equivalents. Dask's schedulers scale to thousand-node clusters and its algorithms have been tested on some of the largest supercomputers in the world.

## Prerequisites

- Kubernetes cluster v1.8+

## Quick deployment on Google Cloud 

  This repository contains `cluster.sh`, a limited utility script to automate the startup and teardown of cluster's running Kolotoc. Currently, `cluster.sh` only supports Google Cloud. 

### Start Cluster

  Assuming you have installed the [Google Cloud SDK](https://cloud.google.com/sdk/) and authenticated to the appropriate account, run `./cluster.sh --num-worker-nodes 2 --machine-type n1-standard-2` to start a two worker distributed ring on Google Cloud n1-standard-2 instances. Type `./cluster.sh --help` for a list of available options.

### Interacting with the Cluster
  
  The utility script will output several addresses that may be navigated to in order to view:
    -Tensorboard
    -JupyterLab
    -Dask Bokeh 

  You may also interact with the cluster by directly interacting with the scheduler node via the printed ```kubectl exec ... -it /bin/bash``` command. Once inside the scheduler node, type run `goto 0` to navigate to worker node rank 0 or `goto n` to navigate to worker node rank n. If each worker-node has been loaded with a Git repository (via a custom Dockerfile), you may run `update` to pull the latest repository on each worker node. 

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
