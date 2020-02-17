# Short Description:
# A set of open source technologies enabling the training and evaluation
# of deep neural networks at scale.
# Dask (data) + Tensorflow (computation) + Horovod (management) + MPI (communication)

# Maintainer: Nathan Matare
# Email: nathan.matare@gmail.com
# Developer Notes:
# (1) This dockerfile is modified from Horovod's because the Horovod images installs
#     python packages with pip whereas the Dask notebook Dockerfile installs
#     packages with conda, resulting in multiple libraries frustratingly
#     installed into different directories. Conda is used hereinafter.

# Install nvidia-docker image and set configuration details

FROM nvidia/cuda:10.0-cudnn7-devel-ubuntu16.04
LABEL maintainer "Nathan Matare <nathan.matare@gmail.com>"

ARG TENSORFLOW_VERSION=2.0.0
ARG HOROVOD_VERSION=0.18.2
ARG CONDA_VERSION=4.7.10
ARG MINICONDA_VERSION=4.6.14 

ENV NB_UID='1000' \
  NB_GID='100' \
  LC_ALL=C.UTF-8 \
  LANG=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive \
  GCSFUSE_REPO=gcsfuse-xenial

RUN apt-get update && apt-get install -y --allow-downgrades \
  --allow-change-held-packages --no-install-recommends \
  build-essential \
  cmake \
  git \
  curl \
  vim \
  wget \
  unzip \
  tmux \
  g++-4.8 \
  libnccl2 \
  libnccl-dev \
  dbus \
  htop \
  pciutils \
  debhelper \ 
  dkms \
  lsb-core \
  librdmacm1 \
  libibverbs1 \
  apt-transport-https \
  ca-certificates \
  libjpeg-dev \
  libpng-dev \
  bzip2 \
  graphviz \
  fonts-liberation \
  nano \
  net-tools \
  openssh-client \
  openssh-server \
  sudo && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Add tini for Docker container runtime
ADD https://github.com/krallin/tini/releases/download/v0.18.0/tini /sbin/tini
RUN chmod +x /sbin/tini

# Install nv_peer_memory
# https://github.com/horovod/horovod/blob/master/docs/gpus.rst
# https://www.mellanox.com/page/products_dyn?product_family=295&mtag=gpudirect
# RUN apt-get update && apt-get install -y ethtool libtool libnl-route-3-dev \
#  libselinux1-dev libltdl-dev libglib2.0-dev libnl-route-3-200 make \
#  libstdc++6 debhelper libssl-dev \
#  libglib2.0-dev libnl-route-3-200 make libstdc++6 debhelper libssl-dev \
#  libnuma-dev dkms libgfortran3 libnl-3-200 libdb-dev pkg-config quilt \
#  libnl-3-dev gfortran gcc libcr-dev automake libnuma1 chrpath bzip2 lsof \
#  autoconf linux-headers-4.15.0-64-generic libmnl0 dh-autoreconf swig \
#  libelf-dev libmnl-dev dpatch build-essential && \
#  apt-get clean && \
#  rm -rf /var/lib/apt/lists/*
# COPY MLNX_OFED_SRC-debian-4.7-1.0.0.1.tgz /tmp/mlnx/
# RUN tmp/mlnx/tar -xzf MLNX_OFED_SRC-debian-4.7-1.0.0.1.tgz && \
#  cd /tmp/mlnx/MLNX_OFED_SRC-4.7-1.0.0.1 && ./install.pl && \
#  /etc/init.d/openibd restart
# RUN git clone https://github.com/Mellanox/nv_peer_memory.git /tmp/nv_peer_memory && \
#  cd /tmp/nv_peer_memory && ./build_module.sh && \
#  cd /tmp && tar -xzf /tmp/nvidia-peer-memory_1.0.orig.tar.gz && cd nvidia-peer-memory-1.0 && \
#  dpkg-buildpackage -us -uc #&& \
#  dpkg -i nvidia-peer-memory_1.0-8_all.deb
#  dpkg -i nvidia-peer-memory-dkms_1.0-8_all.deb

# Install avro-tools
# https://github.com/apache/parquet-mr/tree/master/parquet-tools
RUN apt-get update && apt-get install -y openjdk-8-jdk && \
  wget http://www.us.apache.org/dist/avro/avro-1.9.1/java/avro-tools-1.9.1.jar --directory-prefix=/etc/avro && \
  echo "alias avro-tools='java -jar /etc/avro/avro-tools-1.9.1.jar'" >> /etc/bash.bashrc

# Install GCSFuse 
RUN echo "deb http://packages.cloud.google.com/apt $GCSFUSE_REPO main" | sudo tee /etc/apt/sources.list.d/gcsfuse.list && \ 
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add - && \
  apt-get update && \
  apt-get install -y gcsfuse && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"
RUN echo NCCL_DEBUG=DEBUG >> /etc/nccl.conf && \
  rm /etc/update-motd.d/10-help-text

# Install Conda, Dask, and Jupyter Notebook
ENV CONDA_DIR=/opt/conda \
  PATH=/opt/conda/bin:$PATH 

RUN cd /tmp && \
  wget --quiet https://repo.continuum.io/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh && \
  echo "718259965f234088d785cad1fbd7de03 *Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh" | md5sum -c - && \
  /bin/bash Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh -f -b -p $CONDA_DIR && \
  rm Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh && \
  echo "conda ${CONDA_VERSION}" >> $CONDA_DIR/conda-meta/pinned && \
  $CONDA_DIR/bin/conda config --system --prepend channels conda-forge && \
  $CONDA_DIR/bin/conda config --system --set auto_update_conda false && \
  $CONDA_DIR/bin/conda config --system --set show_channel_urls true && \
  $CONDA_DIR/bin/conda install --quiet --yes conda && \
  $CONDA_DIR/bin/conda update --all --quiet --yes && \
  conda list python | grep '^python ' | tr -s ' ' | cut -d '.' -f 1,2 | sed 's/$/.*/' >> $CONDA_DIR/conda-meta/pinned && \
  conda clean --all -f -y && \
  rm -rf /home/$NB_USER/.cache/yarn 

RUN conda install --quiet --yes --freeze-installed \
  -c conda-forge \
  python-blosc \
  cytoolz \
  dask==2.6.0 \
  nomkl \
  numpy==1.17.2 \
  pandas==0.25.2 \
  ipywidgets \
  dask-labextension==1.0.3 \
  python-graphviz \
  notebook=6.0.0 \
  jupyterhub=1.0.0 \
  jupyterlab=1.1.3 && \
  jupyter notebook --generate-config && \
  npm cache clean --force && \
  conda clean --all -f -y && \
  jupyter lab clean && \
  jlpm cache clean && \
  rm -rf /opt/conda/pkgs && \
  rm -rf $CONDA_DIR/share/jupyter/lab/staging

# Default password is 'kolotoc': it's very advisable to change the default password
RUN openssl req -x509 -nodes -days 666 -newkey rsa:4096 \
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

# Add extensions and configure Jupyter notebook
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - && \
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list && \
  apt-get update && apt-get install -y --no-install-recommends \
  yarn nodejs && \
  wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.34.0/install.sh | bash && \
  pip install jupyter-server-proxy jupyter_contrib_nbextensions dask_labextension && \
  jupyter contrib nbextension install && \
  jupyter nbextension enable spellchecker/main && \
  jupyter labextension install @jupyter-widgets/jupyterlab-manager dask-labextension && \
  jupyter labextension install @jupyterlab/celltags dask-labextension && \
  jupyter serverextension enable --py --sys-prefix dask_labextension

# Install an MPI implementation
# Building from source requires developer tools. https://www.open-mpi.org/source/building.php
RUN apt-get update && apt-get install -y m4 autoconf automake libtool flex

# Install Open-MPI-4.0.0
RUN mkdir /tmp/openmpi && \
  cd /tmp/openmpi && \
  wget https://www.open-mpi.org/software/ompi/v4.0/downloads/openmpi-4.0.0.tar.gz && \
  tar zxf openmpi-4.0.0.tar.gz && \
  cd openmpi-4.0.0 && \
  ./configure --enable-orterun-prefix-by-default && \
  make -j $(nproc) all && \
  make install && \
  ldconfig && \
  rm -rf /tmp/openmpi

# Configure OpenMPI to run good defaults:
RUN echo "hwloc_base_binding_policy = none" >> /usr/local/etc/openmpi-mca-params.conf && \
  echo "rmaps_base_mapping_policy = slot" >> /usr/local/etc/openmpi-mca-params.conf && \
  echo "btl_tcp_if_exclude = lo,docker0" >> /usr/local/etc/openmpi-mca-params.conf && \
  mkdir -p /var/run/sshd

# Install Python packages into the conda base env using CUDA stubs
# https://www.anaconda.com/blog/developer-blog/using-pip-in-a-conda-environment/
RUN pip install tensorflow-gpu==${TENSORFLOW_VERSION} && \
  ldconfig /usr/local/cuda/targets/x86_64-linux/lib/stubs && \
  CXX=/usr/bin/g++-4.8 HOROVOD_GPU_ALLREDUCE=NCCL HOROVOD_WITH_TENSORFLOW=1 \
    pip install horovod==${HOROVOD_VERSION} --no-cache-dir && \
  ldconfig

RUN mkdir -p /scratch
WORKDIR /root