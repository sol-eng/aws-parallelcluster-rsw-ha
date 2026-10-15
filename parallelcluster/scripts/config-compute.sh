#!/bin/bash
#
# Compute node OnNodeConfigured action (all Slurm queues, see
# config/cluster-config-wb.*.tmpl). Installs the Workbench session components
# so that launcher sessions can run on this node.
#
# Args: $1 PWB_VERSION
# Placeholders wrapped in double @ signs are filled in by deploy.sh before upload.

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

# Session components (downloaded to /opt/rstudio/scripts by the head node;
# Posit only publishes jammy builds, which are used on noble as well)
apt -o DPkg::Lock::Timeout=300 update -y
apt -o DPkg::Lock::Timeout=300 install -y curl libcurl4-gnutls-dev libssl-dev libpq5 rrdtool
mkdir -p /usr/lib/rstudio-server
tar xf /opt/rstudio/scripts/rsp-session-jammy-$1-amd64.tar.gz -C /usr/lib/rstudio-server --strip-components=1


if ( ! grep "@@AD_DNS@@" /etc/hosts >& /dev/null ); then
        echo "@@AD_DNS@@ @@AD_DOMAIN@@" >> /etc/hosts
	systemctl restart sssd
fi

# Demo admin user gets passwordless sudo
echo "posit0001   ALL=NOPASSWD: ALL" > /etc/sudoers.d/posit0001
chmod 0440 /etc/sudoers.d/posit0001

if [ "@@EASYBUILD_SUPPORT@@" = true ]
then
    apt -o DPkg::Lock::Timeout=300 update
    apt -o DPkg::Lock::Timeout=300 install -y lmod
    cat << EOF > /etc/profile.d/modulepath.sh
#!/bin/bash

export MODULEPATH=/opt/apps/easybuild/modules/all
EOF
fi
