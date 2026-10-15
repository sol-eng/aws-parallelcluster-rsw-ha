#!/bin/bash
#
# NVIDIA driver for GPU queues. Official ParallelCluster AMIs normally ship an
# NVIDIA driver already; we only install one from the CUDA repo if none is
# present, to avoid replacing the driver ParallelCluster was tested with.

export DEBIAN_FRONTEND=noninteractive

if [ -x /usr/bin/nvidia-smi ] || dpkg -l | grep -q '^ii  nvidia-driver'; then
    echo "NVIDIA driver already installed, skipping"
    exit 0
fi

REPO=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64

install -d -m 0755 /etc/apt/keyrings
curl -fsSL $REPO/3bf863cc.pub | gpg --dearmor -o /etc/apt/keyrings/cuda-archive-keyring.gpg
curl -fsSL -o /etc/apt/preferences.d/cuda-repository-pin-600 $REPO/cuda-ubuntu2404.pin
echo "deb [signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] $REPO/ /" > /etc/apt/sources.list.d/cuda.list

apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y cuda-drivers
