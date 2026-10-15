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
        efsmount=$(awk '$2 == "/opt/rstudio" {print $1}' /etc/fstab)
        mount -t efs ${efsmount}scratch /scratch
	chmod 777 /scratch
fi

# System dependencies of the session components
apt -o DPkg::Lock::Timeout=300 update -y
apt -o DPkg::Lock::Timeout=300 install -y curl libcurl4-gnutls-dev libssl-dev libpq5 rrdtool

# Apptainer for container sessions. Baked into the custom AMI; installed here
# when running on the official ParallelCluster AMI.
if [ "@@SINGULARITY_SUPPORT@@" = true ] && ! command -v apptainer >/dev/null; then
        APPTAINER_VERSION=@@APPTAINER_VERSION@@
        apptainer_tmp=$(mktemp -d)
        for name in apptainer apptainer-suid; do
                curl -fsSL -o $apptainer_tmp/${name}_${APPTAINER_VERSION}_amd64.deb \
                        https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/${name}_${APPTAINER_VERSION}_amd64.deb
        done
        apt -o DPkg::Lock::Timeout=300 install -y $apptainer_tmp/apptainer_${APPTAINER_VERSION}_amd64.deb $apptainer_tmp/apptainer-suid_${APPTAINER_VERSION}_amd64.deb
        rm -rf $apptainer_tmp
fi

# Session components: squashfs image built by the head node on the shared EFS
# (install-pwb-config.sh), mounted read-only at /usr/lib/rstudio-server
SQSH_FILE=/opt/rstudio/session-components/rsw-session-$1.sqsh
SECONDS=0
until [ -f $SQSH_FILE ]; do
        if [ $SECONDS -ge 1800 ]; then echo "ERROR: $SQSH_FILE not found"; exit 1; fi
        sleep 5
done
# threads=multi (parallel decompression) needs kernel support; fall back if absent
SQSH_OPTS=ro,loop,threads=multi
if ! mountpoint -q /usr/lib/rstudio-server; then
        rm -rf /usr/lib/rstudio-server
        mkdir -p /usr/lib/rstudio-server
        if ! mount -t squashfs -o $SQSH_OPTS $SQSH_FILE /usr/lib/rstudio-server; then
                SQSH_OPTS=ro,loop
                mount -t squashfs -o $SQSH_OPTS $SQSH_FILE /usr/lib/rstudio-server
        fi
        if ! grep -q " /usr/lib/rstudio-server squashfs " /etc/fstab; then
                echo "$SQSH_FILE /usr/lib/rstudio-server squashfs $SQSH_OPTS,_netdev,x-systemd.requires-mounts-for=/opt/rstudio 0 0" >> /etc/fstab
        fi
fi


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
