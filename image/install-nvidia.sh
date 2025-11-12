#!/bin/bash

   wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin
   mv cuda-ubuntu2404.pin /etc/apt/preferences.d/cuda-repository-pin-600
   apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub
   add-apt-repository -y "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /"
   apt -o DPkg::Lock::Timeout=300 update
   apt -o DPkg::Lock::Timeout=300 -y install nvidia-drivers 
