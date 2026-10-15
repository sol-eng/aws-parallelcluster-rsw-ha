#!/bin/bash
#
# Login node OnNodeConfigured action (see config/cluster-config-wb.*.tmpl).
# Installs Workbench and activates the config the head node writes to
# /opt/rstudio. Works on the custom AMI and on the official ParallelCluster AMI.
#
# Args: $1 PWB_CONFIG_DIR  $2 PWB_VERSION
# Placeholders wrapped in double @ signs are filled in by deploy.sh before upload.

set -x

exec >> /var/log/config-login.log
exec 2>&1

# Demo admin user gets passwordless sudo
echo "posit0001   ALL=NOPASSWD: ALL" > /etc/sudoers.d/posit0001
chmod 0440 /etc/sudoers.d/posit0001

# Install Posit Workbench

PWB_CONFIG_DIR=$1

PWB_VERSION=$2

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# Add rstudio-server user and group
getent group rstudio-server >/dev/null || groupadd --system --gid 900 rstudio-server
id rstudio-server >/dev/null 2>&1 || useradd -s /bin/bash -m --system --gid rstudio-server --uid 900 rstudio-server

# Workbench admin groups (admin-group / admin-superuser-group in rserver.conf)
getent group rstudio-admins >/dev/null || groupadd --system --gid 8788 rstudio-admins
getent group rstudio-superuser-admins >/dev/null || groupadd --system --gid 8789 rstudio-superuser-admins

# Create home directories on first login
pam-auth-update --enable mkhomedir

# Wait until the head node has written the Workbench config. It downloads the
# Workbench package before that, so the .deb is complete once rserver.conf exists.
SECONDS=0
until [ -f $PWB_CONFIG_DIR/rserver.conf ]; do
    if [ $SECONDS -ge 6900 ]; then echo "ERROR: $PWB_CONFIG_DIR/rserver.conf not found"; exit 1; fi
    sleep 5
done
echo "PWB config files found !"

# Apptainer (baked into the custom AMI; installed here on the official
# ParallelCluster AMI). Sessions run on the compute nodes, but having it on the
# login nodes lets users pull/convert images and use apptainer interactively.
if [ "@@SINGULARITY_SUPPORT@@" = true ] && ! command -v apptainer >/dev/null; then
    APPTAINER_VERSION=@@APPTAINER_VERSION@@
    apptainer_tmp=$(mktemp -d)
    for name in apptainer apptainer-suid; do
        curl -fsSL -o $apptainer_tmp/${name}_${APPTAINER_VERSION}_amd64.deb \
            https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/${name}_${APPTAINER_VERSION}_amd64.deb
    done
    apt-get -o DPkg::Lock::Timeout=300 install -y $apptainer_tmp/apptainer_${APPTAINER_VERSION}_amd64.deb $apptainer_tmp/apptainer-suid_${APPTAINER_VERSION}_amd64.deb
    rm -rf $apptainer_tmp
fi

# Install software
if ( ! dpkg -l gdebi-core >& /dev/null); then
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 install -y gdebi
fi
gdebi -n /opt/rstudio/scripts/rstudio-workbench-${PWB_VERSION}-amd64.deb

cat << EOF > /etc/logrotate.d/rstudio
/var/log/rstudio/rstudio-server/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 rstudio-server rstudio-server
    su rstudio-server rstudio-server
    sharedscripts
    prerotate
        systemctl stop rstudio-server
    endscript
    postrotate
        systemctl start rstudio-server
    endscript
}

/var/log/rstudio/launcher/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 rstudio-server rstudio-server
    su rstudio-server rstudio-server
    sharedscripts
    prerotate
        systemctl stop rstudio-launcher
    endscript
    postrotate
        systemctl start rstudio-launcher
    endscript
}
EOF

systemctl restart logrotate

VSCODE_EXTDIR=/usr/local/rstudio/code-server

mkdir -p /usr/local/rstudio/code-server
chmod a+rx /usr/local/rstudio/code-server

for extension in quarto.quarto \
        REditorSupport.r \
        ms-python.python
do
   /usr/lib/rstudio-server/bin/pwb-code-server/bin/code-server --extensions-dir=$VSCODE_EXTDIR \
                        --install-extension $extension
done

chmod a+rx /usr/local/rstudio/code-server


rm -rf /etc/rstudio
mkdir -p /etc/rstudio

cp -dpRf $PWB_CONFIG_DIR/* /etc/rstudio

# Workbench load balancing: nodes address each other by their EC2 private DNS
# name (resolved by the VPC DNS), so no host list needs to be maintained
imds_token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
my_hostname=$(curl -sf -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/local-hostname)
echo "www-host-name=$my_hostname" > /etc/rstudio/load-balancer

# add the self-signed SSL cert (SSL=true only) locally to make the workbench LB happy
if [ -f /opt/rstudio/etc/@@HPC_DOMAIN@@.crt ]; then
    cp /opt/rstudio/etc/@@HPC_DOMAIN@@.crt /usr/local/share/ca-certificates
    update-ca-certificates
fi

# scalability
sysctl -w net.unix.max_dgram_qlen=8192
sysctl -w net.core.netdev_max_backlog=65535

systemctl daemon-reload
systemctl stop rstudio-server
systemctl stop rstudio-launcher
killall apache2
logrotate -f /etc/logrotate.d/rstudio
systemctl start rstudio-launcher
systemctl start rstudio-server

# Touch a file in /opt/rstudio to signal that workbench is running on this server
touch /opt/rstudio/workbench-`hostname`.state

# Register with the ALB target groups now and on every boot, deregister on
# shutdown, and clean up targets/Workbench nodes of login nodes that are gone
aws s3 cp s3://@@S3_PREFIX@@/pwb-lb.sh /usr/local/sbin/pwb-lb
chmod 0755 /usr/local/sbin/pwb-lb
cat << EOF > /etc/systemd/system/pwb-lb.service
[Unit]
Description=Register this login node with the Workbench load balancers
Wants=network-online.target
After=network-online.target rstudio-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pwb-lb register
ExecStop=/usr/local/sbin/pwb-lb deregister
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pwb-lb.service

if [ "@@EASYBUILD_SUPPORT@@" = true ]; then
    apt-get update && apt-get install -y lmod
    cat << EOF > /etc/profile.d/modulepath.sh
#!/bin/bash

export MODULEPATH=/opt/apps/easybuild/modules/all
EOF
fi

if ( ! grep "@@AD_DNS@@" /etc/hosts >& /dev/null ); then
        echo "@@AD_DNS@@ @@AD_DOMAIN@@" >> /etc/hosts
fi


if ( ! grep rstudio-server /etc/security/limits.conf ); then
	echo "rstudio-server  soft    nofile          32768" >> /etc/security/limits.conf
	echo "rstudio-server  hard    nofile          32768" >> /etc/security/limits.conf
fi

if ( ! mount | grep /scratch ); then
        # create scratch folder as part of EFS fs
        mkdir -p /scratch /opt/rstudio/scratch
        efsmount=$(awk '$2 == "/opt/rstudio" {print $1}' /etc/fstab)
        mount -t efs ${efsmount}scratch /scratch
fi

# Done: from now on rc.pwb (cron, every minute) restarts Workbench on this node
# whenever /opt/rstudio/workbench-<hostname>.state is removed
touch /etc/login-node-is-setup
if ! crontab -l 2>/dev/null | grep -q rc.pwb; then
    (crontab -l 2>/dev/null; echo "0-59/1 * * * * /opt/rstudio/scripts/rc.pwb") | crontab -
fi
