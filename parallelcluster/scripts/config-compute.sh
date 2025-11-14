#!/bin/bash

set -x

mkdir -p /opt/rstudio/config-compute
exec > /opt/rstudio/config-compute/`hostname`-`date +%s`.log 
exec 2>&1

# create scratch folder as part of EFS fs
if ( ! mount | grep /scratch ); then
        # create scratch folder as part of EFS fs
        mkdir -p /scratch /opt/rstudio/scratch
        efsmount=`cat /etc/fstab  | grep rstudio | awk '{print $1}'`
        mount -t efs ${efsmount}scratch /scratch
	chmod 777 /scratch 
fi

# Session components
apt -o DPkg::Lock::Timeout=300 update -y
apt -o DPkg::Lock::Timeout=300 install -y curl libcurl4-gnutls-dev libssl-dev libpq5 rrdtool
mkdir -p /usr/lib/rstudio-server
tar xf /opt/rstudio/scripts/rsp-session-jammy-$1-amd64.tar.gz -C /usr/lib/rstudio-server --strip-components=1


if ( ! grep AD_DNS /etc/hosts >& /dev/null ); then
        echo "AD_DNS pwb.posit.co" >> /etc/hosts
	systemctl restart sssd
fi

if ( ! grep posit0001 /etc/sudoers >& /dev/null ); then
        echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers
fi


echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers

if EASYBUILD_SUPPORT 
then 
    apt -o DPkg::Lock::Timeout=300 update 
    apt -o DPkg::Lock::Timeout=300 install -y lmod 
    cat << EOF > /etc/profile.d/modulepath.sh
#!/bin/bash

export MODULEPATH=/opt/apps/easybuild/modules/all
EOF
fi  
