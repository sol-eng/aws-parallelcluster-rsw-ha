#!/bin/bash

PWB_BASE_DIR="/opt/parallelcluster/shared/rstudio/"

PWB_CONFIG_DIR=$PWB_BASE_DIR/etc/rstudio

mkdir -p $PWB_BASE_DIR/{etc/rstudio,shared-storage,scripts}


# Add SLURM integration 
myip=`curl http://checkip.amazonaws.com`


cat > $PWB_CONFIG_DIR/launcher-env << EOF
RSTUDIO_DISABLE_PACKAGE_INSTALL_PROMPT=yes
SLURM_CONF=/opt/slurm/etc/slurm.conf
EOF
 
cat > $PWB_CONFIG_DIR/rserver.conf << EOF
# Shared storage
server-shared-storage-path=${PWB_BASE_DIR}/shared-storage

# enable load-balancing
load-balancing-enabled=1

# www port 
www-port=8787

# Launcher Config
launcher-address=127.0.0.1
launcher-port=5559
launcher-sessions-enabled=1
launcher-default-cluster=Slurm
launcher-sessions-callback-address=http://${myip}:8787

# Disable R Versions scanning
#r-versions-scan=0

# Location of r-versions JSON file 
r-versions-path=${PWB_BASE_DIR}/shared-storage/r-versions

auth-pam-sessions-enabled=1
#auth-pam-sessions-use-password=1

# Enable Admin Dashboard
admin-enabled=1
admin-group=rstudio-admins
admin-superuser-group=rstudio-superuser-admins
admin-monitor-log-use-server-time-zone=1
audit-r-console-user-limit-mb=200
audit-r-console-user-limit-months=3

# Enable Auditing
audit-r-console=all
audit-r-sessions=1
audit-data-path=${PWB_BASE_DIR}/shared-data/head-node/audit-data
audit-r-sessions-limit-mb=512
audit-r-sessions-limit-months=6


# Enable Monitoring
monitor-data-path=${PWB_BASE_DIR}/shared-data/head-node/monitor-data
EOF

mkdir -p ${PWB_BASE_DIR}/shared-data/head-node/{audit-data,monitor-data}
chown -R rstudio-server ${PWB_BASE_DIR}/shared-data/head-node/

cat > $PWB_CONFIG_DIR/launcher.conf<<EOF
[server]
address=127.0.0.1
port=5559
server-user=rstudio-server
admin-group=rstudio-server
authorization-enabled=1
thread-pool-size=4
enable-debug-logging=1

[cluster]
name=Slurm
type=Slurm

#[cluster]
#name=Local
#type=Local

EOF

cat > $PWB_CONFIG_DIR/launcher.slurm.profiles.conf<<EOF 
#[*]
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurm.resources.conf<<EOF
[small]
name = "Small (1 cpu, 2 GB mem)"
cpus=1
mem-mb=1940
EOF

cat > $PWB_CONFIG_DIR/launcher.slurm.conf << EOF 
# Enable debugging
enable-debug-logging=1

# Basic configuration
slurm-service-user=slurm
slurm-bin-path=/opt/slurm/bin

# GPU specifics
enable-gpus=1
gpu-types=v100

EOF

cat > $PWB_CONFIG_DIR/jupyter.conf << EOF
jupyter-exe=/usr/local/bin/jupyter
notebooks-enabled=1
labs-enabled=1
EOF


VSCODE_EXTDIR=/usr/local/rstudio/code-server

mkdir -p /usr/local/rstudio/code-server
chmod a+rx /usr/local/rstudio/code-server

cat > $PWB_CONFIG_DIR/vscode.conf << EOF
enabled=1
exe=/usr/lib/rstudio-server/bin/code-server/bin/code-server
args=--verbose --host=0.0.0.0 --extensions-dir=$VSCODE_EXTDIR
EOF

# prepare renv package cache
tmpfile=`mktemp`
mkdir -p /data/renv
cat << EOF > $tmpfile
user::rwx
group::rwx
mask::rwx
other::rwx
default:user::rwx
default:group::rwx
default:mask::rwx
default:other::rwx
EOF
setfacl -R --set-file=$tmpfile /data/renv
rm -rf $tmpfile

#prepare for singularity integration 
mkdir -p ${PWB_BASE_DIR}/containers


cat << EOF > $PWB_CONFIG_DIR/database.conf
provider=postgresql
host=ukhsa-rsw-dbca27dc2.clovh3dmuvji.eu-west-1.rds.amazonaws.com
database=pwb
port=5432
username=pwb_db_admin
password=pwb_db_password
connection-timeout-seconds=10
EOF


openssl genpkey -algorithm RSA \
            -out $PWB_CONFIG_DIR/launcher.pem \
            -pkeyopt rsa_keygen_bits:2048 && \
    chown rstudio-server:rstudio-server \
            $PWB_CONFIG_DIR/launcher.pem && \
    chmod 0600 $PWB_CONFIG_DIR/launcher.pem

openssl rsa -in $PWB_CONFIG_DIR/launcher.pem \
            -pubout > $PWB_CONFIG_DIR/launcher.pub && \
    chown rstudio-server:rstudio-server \
            $PWB_CONFIG_DIR/launcher.pub



sudo chmod 0600 $PWB_CONFIG_DIR/database.conf




cat << EOF > $PWB_BASE_DIR/scripts/rc.pwb 
#!/bin/bash

set -x 

exec > /var/log/rc.pwb.log
exec 2>&1

if (mount | grep login_node >&/dev/null);  then 
    # we are on a login node and need to start the workbench processes 
    # but we need to make sure the config files are all there
    #if [ ! -f /etc/ssh/sshd_config.d/ukhsa.conf ]; then 
    #    echo "Port 3000" > /etc/ssh/sshd_config.d/ukhsa.conf
    #    systemctl restart sshd
    #fi
    while true ; do if [ -f /opt/parallelcluster/shared/rstudio/etc/rstudio/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"
    if [ ! -f /etc/systemd/system/rstudio-server.service.d/override.conf ]; then 
        # systemctl overrides
        for i in server launcher 
        do 
            mkdir -p /etc/systemd/system/rstudio-\$i.service.d
            echo -e "[Service]\nEnvironment=\"RSTUDIO_CONFIG_DIR=/opt/parallelcluster/shared/rstudio/etc/rstudio\"" > /etc/systemd/system/rstudio-\$i.service.d/override.conf
        done
        # We are on a login node and hence will need to enable rstudio-server and rstudio-launcher
        systemctl daemon-reload
        systemctl enable rstudio-server
        systemctl enable rstudio-launcher
        rm -f /var/lib/rstudio-server/secure-cookie-key
        rm -f /opt/parallelcluster/shared/rstudio/etc/rstudio/launcher.pub
        rm -f /opt/parallelcluster/shared/rstudio/etc/rstudio/launcher.pem
        systemctl start rstudio-launcher
        systemctl start rstudio-server
        rm -f /var/lib/rstudio-server/secure-cookie-key
        systemctl restart rstudio-server 
    fi    
    
fi

if ( ! grep 172.31.34.129 /etc/hosts >& /dev/null ); then 
        echo "172.31.34.129 pwb.posit.co" >> /etc/hosts
fi

if ( ! grep posit0001 /etc/sudoers >& /dev/null ); then 
        echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers
fi

EOF

chmod +x $PWB_BASE_DIR/scripts/rc.pwb 
