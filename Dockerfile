# Short Description: 
# A set of open source technologies enabling the training and evaluation
# of deep neural networks at scale. 
# Dask (data) + Tensorflow (computation) + Horovod (management) + MPI (communication)

# Maintainer: Nathan Matare
# Email: nathan.matare@gmail.com
# Developer Notes: 
# (1) https://github.com/moby/moby/issues/35018; open issue cannot chown here
#     $NB_USER is set from jupyter/base-notebook as 'jovyan'
# (2) This dockerfile is modified from Horovod's because the Horovod images installs 
#     python packages with pip whereas the Dask notebook Dockerfile installs 
#     packages with conda, resulting in multiple libraries frustratingly 
#     installed into different directories. Conda is used hereinafter. 

# Install nvidia-docker image and set configuration details
FROM nvidia/cuda:10.0-cudnn7-devel-ubuntu16.04 
LABEL maintainer "Nathan Matare <nathan.matare@gmail.com>"
ENV NB_USER='jovyan'\
  NB_UID='1000' \
  NB_GID='100' \
  LC_ALL=C.UTF-8 \
  LANG=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive
  
RUN apt-get update && apt-get install -y --allow-downgrades \ 
  --allow-change-held-packages --no-install-recommends \
  build-essential \
  cmake \
  git \
  curl \
  vim \
  wget \
  unzip \
  libnccl2 \ 
  libnccl-dev \
  dbus \
  pciutils \ 
  apt-transport-https \
  ca-certificates \
  libjpeg-dev \
  libpng-dev \
  bzip2 \
  graphviz \
  fonts-liberation \
  nano \
  openssh-client \ 
  openssh-server \
  sudo && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* 

ENV PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"
RUN echo NCCL_DEBUG=DEBUG >> /etc/nccl.conf && \
  rm /etc/update-motd.d/10-help-text

# 'Install' Dask and Jupyter from daskdev/dask-notebook 
# Unlike 'FROM daskdev/dask-notebook' which copies environment variables, 
# 'COPY --from=daskdev/dask-notebook' does not, so these must be set.
# https://github.com/moby/moby/issues/34482
FROM daskdev/dask-notebook:latest AS dask
COPY --from=dask \ 
  /home /opt /usr/local/bin/*.sh /usr/local/bin/fix-permissions \
  /usr/bin/*.sh /etc/jupyter /etc/passwd /etc/shadow /etc/group \ 
  /etc/gshadow /tmp/

RUN awk '/^jovyan/' /tmp/passwd >> /etc/passwd && \
  awk '/^jovyan/' /tmp/shadow  >> /etc/shadow && \
  awk '/^wheel/' /tmp/group >> /etc/group && \
  awk '/^wheel/' /tmp/gshadow  >> /etc/gshadow && \
  mv /tmp/*.sh /tmp/fix-permissions /usr/local/bin/ && \
  mv /tmp/conda /tmp/app /opt && fix-permissions /opt/conda && \ 
  mv /tmp/${NB_USER} /home/${NB_USER} && fix-permissions /home/${NB_USER} && \
  rm -rf /tmp/*

# Default password is 'kolotoc': it's very advisable to change the default password
RUN mkdir /root/.jupyter/ && \
  openssl req -x509 -nodes -days 666 -newkey rsa:4096 \
    -keyout /root/.jupyter/jupyter.key -out /root/.jupyter/jupyter.pem \
    -subj "/C=US/ST=IL/L=Springfield/O=kolotoc/CN=www.dask.org" && \
  echo "c = get_config()" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.certfile = u'/root/.jupyter/jupyter.pem'" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.keyfile = u'/root/.jupyter/jupyter.key'" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.password = u'sha1:8d3e7a39bc1a:5f6a4b9fd8dc5feb8ed6f70fa0839ea200d8ebbe'" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.ip = '*'" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.allow_remote_access=True" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.open_browser = False" >> /root/.jupyter/jupyter_notebook_config.py && \
  echo "c.NotebookApp.port = 8888" >> /root/.jupyter/jupyter_notebook_config.py 

# Install an MPI implementation 
# Building from source requires developer tools. https://www.open-mpi.org/source/building.php
RUN apt-get update && apt-get install -y \
 m4 \ 
 autoconf \
 automake \
 libtool \ 
 flex

# Install Open-MPI-3.1.2
RUN mkdir /tmp/openmpi && \
  cd /tmp/openmpi && \
  wget https://www.open-mpi.org/software/ompi/v3.1/downloads/openmpi-3.1.2.tar.gz && \
  tar zxf openmpi-3.1.2.tar.gz && \
  cd openmpi-3.1.2 && \
  ./configure --enable-orterun-prefix-by-default && \
  make -j $(nproc) all && \
  make install && \
  ldconfig && \
  rm -rf /tmp/openmpi

# Install MPI-ULFM2 http://fault-tolerance.org/ulfm/downloads/
#RUN mkdir /tmp/openmpi && \
# cd /tmp/openmpi && \
# wget https://bitbucket.org/icldistcomp/ulfm2/get/04b0a92b540b.zip && \
# unzip 04b0a92b540b.zip && \
# cd icldistcomp-ulfm2-04b0a92b540b && \
# ./autogen.pl && \
# ./configure --enable-orterun-prefix-by-default --with-ft=mpi && \
# make -j $(nproc) all && \
# make install && \
# ldconfig && \
# rm -rf /tmp/openmpi

# Configure OpenMPI to run good defaults:
RUN echo "hwloc_base_binding_policy = none" >> /usr/local/etc/openmpi-mca-params.conf && \
  echo "rmaps_base_mapping_policy = slot" >> /usr/local/etc/openmpi-mca-params.conf && \
  echo "btl_tcp_if_exclude = lo,docker0" >> /usr/local/etc/openmpi-mca-params.conf && \
  mkdir -p /var/run/sshd

# Install Python packages into the conda base env using CUDA stubs 
# https://www.anaconda.com/blog/developer-blog/using-pip-in-a-conda-environment/
ENV PATH=/opt/conda/bin:$PATH 
RUN pip install tensorflow-gpu && \
  ldconfig /usr/local/cuda-10.0/targets/x86_64-linux/lib/stubs && \
  HOROVOD_GPU_ALLREDUCE=NCCL HOROVOD_WITH_TENSORFLOW=1 pip install horovod --no-cache-dir && \
  ldconfig

WORKDIR /root

