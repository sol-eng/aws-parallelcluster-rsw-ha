#!/bin/bash

#setup GPUs

if ( lspci | grep NVIDIA ); then 
   wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-ubuntu2004.pin
   mv cuda-ubuntu2004.pin /etc/apt/preferences.d/cuda-repository-pin-600
   apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/3bf863cc.pub
   add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/ /"
   apt-get update
   apt-get -y install cuda libcudnn8-dev
   rmmod gdrdrv
   rmmod nvidia
   modprobe nvidia
fi

echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers

if (BENCHMARK_SUPPORT); then 
   # Perform the initial population of /opt/rstudio/rstudio-server if it doesn't exist. This lets the first deployed
   # compute work right away
   if [ ! -d "/opt/rstudio/rstudio-server" ]; then
     cp -R /usr/lib/rstudio-server /opt/rstudio/
   fi
   # symlink /opt/rstudio/rstudio-server into /usr/lib/rstudio-server
   rm -rf /usr/lib/rstudio-server
   ln -s /opt/rstudio/rstudio-server /usr/lib

fi

# create scratch folder as part of EFS fs
mkdir -p /scratch /opt/rstudio/scratch 
efsmount=`cat /etc/fstab  | grep rstudio | awk '{print $1}'`
mount ${efsmount}scratch /scratch