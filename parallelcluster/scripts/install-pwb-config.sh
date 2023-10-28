#!/bin/bash

PWB_CONFIG_DIR="/opt/rstudio/etc/rstudio"

mkdir -p /opt/rstudio
    grep slurm /etc/exports | sed 's/slurm/rstudio/' | sudo tee -a /etc/exports
    exportfs -ar


mkdir -p $PWB_CONFIG_DIR


# Add SLURM integration 
myip=`curl http://checkip.amazonaws.com`

mkdir -p /opt/rstudio/shared-storage

cat > $PWB_CONFIG_DIR/launcher-env << EOF
RSTUDIO_DISABLE_PACKAGE_INSTALL_PROMPT=yes
SLURM_CONF=/opt/slurm/etc/slurm.conf
EOF
 
cat > $PWB_CONFIG_DIR/rserver.conf << EOF
# Shared storage
server-shared-storage-path=/opt/rstudio/shared-storage

# enable load-balancing
load-balancing-enabled=1

# Launcher Config
launcher-address=127.0.0.1
launcher-port=5559
launcher-sessions-enabled=1
launcher-default-cluster=Slurm
launcher-sessions-callback-address=http://${myip}:8787

# Disable R Versions scanning
#r-versions-scan=0

# Location of r-versions JSON file 
r-versions-path=/opt/rstudio/shared-storage/r-versions

auth-pam-sessions-enabled=1
auth-pam-sessions-use-password=1

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
audit-data-path=/opt/rstudio/shared-data/head-node/audit-data
audit-r-sessions-limit-mb=512
audit-r-sessions-limit-months=6


# Enable Monitoring
monitor-data-path=/opt/rstudio/shared-data/head-node/monitor-data
EOF

mkdir -p /opt/rstudio/shared-data/head-node/{audit-data,monitor-data}
chown -R rstudio-server /opt/rstudio/shared-data/head-node/

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
name = "Small (1 cpu, 4 GB mem)"
cpus=1
mem-mb=4096
[medium]
name = "Medium (4 cpu, 16 GB mem)"
cpus=4
mem-mb=16384
[large]
name = "Large (8 cpu, 32 GB mem)"
cpus=8
mem-mb=32768
[xlarge]
name = "Extra Large (16 cpu, 64 GB mem)"
cpus=16
mem-mb=65536
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
mkdir -p /opt/rstudio/containers


cat << EOF > $PWB_CONFIG_DIR/database.conf
provider=postgresql
host=ukhsa-rsw-dbe204aac.clovh3dmuvji.eu-west-1.rds.amazonaws.com
database=rsw
port=5432
username=rsw_db_admin
password=password
connection-timeout-seconds=10
EOF

sudo chmod 0600 $PWB_CONFIG_DIR/database.conf