#!/bin/bash

# Grant posit0001 sudo rights
echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers

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
        REditorSupport.r@2.6.1 \
        ms-python.python@2022.10.1
do
   /usr/lib/rstudio-server/bin/pwb-code-server/bin/code-server --extensions-dir=$VSCODE_EXTDIR \
                        --install-extension $extension
done

chmod a+rx /usr/local/rstudio/code-server


# wait until the workbench config files are there (deployed by head-node)
while true ; do if [ -f $PWB_CONFIG_DIR/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"

my_ip=`ifconfig | grep inet | awk '{print $2}'| head -1`

REAL_PWB_CONFIG_DIR=${PWB_CONFIG_DIR/.tmpl/}

rm -rf /etc/rstudio
mkdir -p /etc/rstudio
#mm ln -s /etc/rstudio ${REAL_PWB_CONFIG_DIR%rstudio*}

cp -dpRf $PWB_CONFIG_DIR/* /etc/rstudio

# add DNS entries for LB nodes 
cat  $PWB_CONFIG_DIR/nodes >> /etc/hosts

my_hostname=`grep $my_ip /etc/hosts | tail -1  | awk '{print $3}'`

echo "www-host-name=$my_hostname" > /etc/rstudio/load-balancer

# add SSL Cert locally to make workbench LB happy
cp /opt/rstudio/etc/$HPC_DOMAIN.crt /usr/local/share/ca-certificates 
update-ca-certificates

# systemctl overrides

# for i in server launcher 
# do 
#     mkdir -p /etc/systemd/system/rstudio-$i.service.d
#     echo -e "[Service]\nEnvironment=\"RSTUDIO_CONFIG_DIR=$REAL_PWB_CONFIG_DIR\"" > /etc/systemd/system/rstudio-$i.service.d/override.conf
# done
# We are on a login node and hence will need to enable rstudio-server and rstudio-launcher

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

#if ( ! crontab -l | grep rstudio ); then 
#    (crontab -l ; echo "0-59/1 * * * * /opt/rstudio/scripts/rc.pwb")| crontab -
#fi

if (EASYBUILD_SUPPORT); then 
    apt-get update && apt-get install -y lmod 
    cat << EOF > /etc/profile.d/modulepath.sh
#!/bin/bash

export MODULEPATH=/opt/apps/easybuild/modules/all
EOF
fi  

if ( ! grep AD_DNS /etc/hosts >& /dev/null ); then 
        echo "AD_DNS pwb.posit.co" >> /etc/hosts
fi

if ( ! grep posit0001 /etc/sudoers >& /dev/null ); then 
        echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers
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

if SINGULARITY_SUPPORT
then 
   APPTAINER_VERSION=1.4.2
   pushd /tmp 
   curl -LO https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer_${APPTAINER_VERSION}_amd64.deb
   curl -LO https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer-suid_${APPTAINER_VERSION}_amd64.deb
   apt install -y ./apptainer_${APPTAINER_VERSION}_amd64.deb ./apptainer-suid_${APPTAINER_VERSION}_amd64.deb
   rm -f ./apptainer_${APPTAINER_VERSION}_amd64.deb ./apptainer-suid_${APPTAINER_VERSION}_amd64.deb
   popd
fi