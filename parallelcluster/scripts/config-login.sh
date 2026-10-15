#!/bin/bash
#
# Login node setup, run once per login node by /opt/rstudio/scripts/rc.pwb
# (written by install-pwb-config.sh, triggered by the cron job in the AMI).
# Installs Workbench and activates the config the head node put on /opt/rstudio.
#
# Args: $1 PWB_CONFIG_DIR  $2 PWB_VERSION
# Placeholders wrapped in double @ signs are filled in by deploy.sh before upload.

# Demo admin user gets passwordless sudo
echo "posit0001   ALL=NOPASSWD: ALL" > /etc/sudoers.d/posit0001
chmod 0440 /etc/sudoers.d/posit0001

# Install Posit Workbench

PWB_CONFIG_DIR=$1

PWB_VERSION=$2

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# Add rstudio-server user and group
groupadd --system --gid 900 rstudio-server
useradd -s /bin/bash -m --system --gid rstudio-server --uid 900 rstudio-server

# Install software

if ( ! dpkg -l gdebi-core >& /dev/null); then
apt-get update
apt-get install -y gdebi
fi

while true
do
    if [ -d /opt/rstudio/scripts ]; then
        pushd /opt/rstudio/scripts
        apt-get update -y
        gdebi -n rstudio-workbench-${PWB_VERSION}-amd64.deb
        popd
        break
    fi
    sleep 5
done

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


# wait until the workbench config files are there (deployed by head-node)
while true ; do if [ -f $PWB_CONFIG_DIR/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"

my_ip=$(hostname -I | awk '{print $1}')

rm -rf /etc/rstudio
mkdir -p /etc/rstudio

cp -dpRf $PWB_CONFIG_DIR/* /etc/rstudio

# add DNS entries for LB nodes
cat  $PWB_CONFIG_DIR/nodes >> /etc/hosts

my_hostname=`grep $my_ip /etc/hosts | tail -1  | awk '{print $3}'`

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
        efsmount=`cat /etc/fstab  | grep rstudio | awk '{print $1}'`
        mount -t efs ${efsmount}scratch /scratch
fi
