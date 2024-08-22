#!/bin/bash

# create scratch folder as part of EFS fs
if ( ! mount | grep /scratch ); then
        # create scratch folder as part of EFS fs
        mkdir -p /scratch /opt/rstudio/scratch
        efsmount=`cat /etc/fstab  | grep rstudio | awk '{print $1}'`
        mount -t efs ${efsmount}scratch /scratch
	chmod 777 /scratch 
fi

# Session components
apt-get update -y
apt-get install -y curl libcurl4-gnutls-dev libssl-dev libpq5 rrdtool
mkdir -p /usr/lib/rstudio-server
tar xf /opt/rstudio/scripts/rsp-session-jammy-$1-amd64.tar.gz -C /usr/lib/rstudio-server --strip-components=1


if ( ! grep AD_DNS /etc/hosts >& /dev/null ); then
        echo "AD_DNS pwb.posit.co" >> /etc/hosts
	systemctl restart sssd
fi

if ( ! grep posit0001 /etc/sudoers >& /dev/null ); then
        echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers
fi

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
   apt clean
   apt install -y nvidia-dkms-560 nvidia-kernel-source-560
fi

echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers

if (EASYBUILD_SUPPORT); then 
    apt-get update && apt-get install -y lmod 
    cat << EOF > /etc/profile.d/modulepath.sh
#!/bin/bash

export MODULEPATH=/opt/apps/easybuild/modules/all
EOF
fi  
