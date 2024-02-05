#!/bin/bash

# This script is run on the head node, we temporarily need to mount the shared directory 
# for the shared_login_nodes in order to populate the rstudio config

set -x 

exec > /var/log/install-pwb-config.log
exec 2>&1

SHARED_DIR=/opt

PWB_BASE_DIR=$SHARED_DIR/rstudio/

PWB_CONFIG_DIR=$PWB_BASE_DIR/etc/rstudio

mkdir -p $PWB_BASE_DIR/{etc/rstudio,scripts,apptainer}

mkdir -p /home/rstudio/shared-storage

SHARED_DATA="/home/rstudio/shared-storage"

# Label this node as head-node so we can detect it later
touch /etc/head-node

if (BENCHMARK_SUPPORT); then 
    # sync /usr/lib/rstudio-server into /opt/rstudio and link it back to original location
    # so that an upgrade to workbench automatically updates files in /opt/rstudio 
    # the idea is to then symlink /opt/rstudio/rstudio-server into /usr/lib/rstudio-server 
    # on all other nodes (login as well as compute nodes)
    rsync -a /usr/lib/rstudio-server /opt/rstudio
    rm -rf /usr/lib/rstudio-server
    ln -s /opt/rstudio/rstudio-server /usr/lib 
fi

# Add SLURM integration 

# wait until ELB is available and then set this to make sure workbench jobs are working

export AWS_DEFAULT_REGION=`cat /opt/parallelcluster/shared/cluster-config.yaml  | grep ^Region | awk '{print $2}'`
cluster_name=`cat /opt/parallelcluster/shared/cluster-config.yaml | awk '/.*cluster.name/{getline; print}' | awk '{print $2}'`

function find_elb_url() {
    elb=""
    while true
        do
            elb=`cluster_name=$1; for i in $(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[].LoadBalancerArn'); do if ( aws elbv2 describe-tags --resource-arns "\$i" | jq --arg cluster_name "$1" -ce '.TagDescriptions[].Tags[] | select( .Key == "parallelcluster:cluster-name" and .Value==$cluster_name)' > /dev/null); then echo $i; fi; done `
            if [ ! -z $elb ]; then break; fi
            sleep 2
        done
    aws elbv2 describe-load-balancers --load-balancer-arns=$elb | jq -r '.[] | .[] | .DNSName'
}

elb_url=$(find_elb_url $cluster_name)


# generate launcher ssl keys
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


# generate secure-cookie-key as a simple UUID
sh -c "echo SECURE_COOKIE_KEY > $PWB_CONFIG_DIR/secure-cookie-key"
chmod 0600 $PWB_CONFIG_DIR/secure-cookie-key

cat > $PWB_CONFIG_DIR/launcher-env << EOF
RSTUDIO_DISABLE_PACKAGE_INSTALL_PROMPT=yes
SLURM_CONF=/opt/slurm/etc/slurm.conf
EOF
 
cat > $PWB_CONFIG_DIR/rserver.conf << EOF
# Shared storage
server-shared-storage-path=$SHARED_DATA

# prevent singularity to attempt creating a user in the container (admin rights)
launcher-sessions-create-container-user=0
# forward environment variables into the container 
launcher-sessions-forward-container-environment=1

# enable load-balancing
load-balancing-enabled=1

# server access log
server-access-log=1

# Launcher Config
launcher-address=127.0.0.1
launcher-port=5559
launcher-sessions-enabled=1
launcher-default-cluster=Slurm
launcher-sessions-callback-address=http://${elb_url}:8787

# Disable R Versions scanning
#r-versions-scan=0

# Location of r-versions JSON file 
r-versions-path=$SHARED_DATA/r-versions

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
audit-data-path=$SHARED_DATA/head-node/audit-data
audit-r-sessions-limit-mb=512
audit-r-sessions-limit-months=6


# Enable Monitoring
monitor-data-path=$SHARED_DATA/head-node/monitor-data

# secure cookie key
secure-cookie-key-file=${PWB_CONFIG_DIR}/secure-cookie-key
EOF

if (MULTIPLE_LAUNCHERS); then 
cat >> $PWB_CONFIG_DIR/rserver.conf << EOF

# multiple launcher support
launcher-sessions-clusters=slurminteractive
launcher-adhoc-clusters=slurmbatch
EOF
fi

mkdir -p $SHARED_DATA/head-node/{audit-data,monitor-data}
chown -R rstudio-server $SHARED_DATA/head-node/


# Add stuff for increased performance 
export pwb_version=`rstudio-server version | cut -d "+" -f 1 | sed 's/\.//g'`
if [ $pwb_version -ge 2023120 ]; then 
        cat > $PWB_CONFIG_DIR/nginx.worker.conf << EOF
worker_processes 1;

worker_rlimit_nofile 8192;

events {
    worker_connections  4096;
}
EOF
fi



if (MULTIPLE_LAUNCHERS); then 
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
name=slurminteractive
type=Slurm
config-file=$PWB_CONFIG_DIR/launcher.slurminteractive.conf

[cluster]
name=slurmbatch
type=Slurm
config-file=$PWB_CONFIG_DIR/launcher.slurmbatch.conf
EOF

else

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
EOF

fi

mkdir -p $PWB_CONFIG_DIR/apptainer

if (MULTIPLE_LAUNCHERS); then

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.conf << EOF 
# Enable debugging
enable-debug-logging=1

# Basic configuration
slurm-service-user=slurm
slurm-bin-path=/opt/slurm/bin

# GPU specifics
enable-gpus=1
gpu-types=v100

# User/group and resource profiles
profile-config=${PWB_CONFIG_DIR}/launcher.slurminteractive.profiles.conf
resource-profile-config=${PWB_CONFIG_DIR}/launcher.slurminteractive.resources.conf
EOF

cat > ${PWB_CONFIG_DIR}/launcher.slurminteractive.profiles.conf << EOF
[*]
allowed-partitions=interactive
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > ${PWB_CONFIG_DIR}/launcher.slurminteractive.resources.conf << EOF
[small]
name = "Small (1 cpu, 2 GB mem)"
cpus=1
mem-mb=1936
#name = "Medium (2 cpu, 4 GB mem)"
#[medium]
#mem-mb=3873
#[large]
#cpus=2
#name = "Large (4 cpu, 8 GB mem)"
#cpus=4
#mem-mb=7746
#[xlarge]
#name = "Extra Large (8 cpu, 16 GB mem)"
#cpus=8
#mem-mb=15493
EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.conf << EOF 
# Enable debugging
enable-debug-logging=1

# Basic configuration
slurm-service-user=slurm
slurm-bin-path=/opt/slurm/bin

# GPU specifics
enable-gpus=1
gpu-types=v100

# User/group and resource profiles
profile-config=${PWB_CONFIG_DIR}/launcher.slurmbatch.profiles.conf
resource-profile-config=${PWB_CONFIG_DIR}/launcher.slurmbatch.resources.conf
EOF

cat > ${PWB_CONFIG_DIR}/launcher.slurmbatch.profiles.conf << EOF
[*]
allowed-partitions=all
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > ${PWB_CONFIG_DIR}/launcher.slurmbatch.resources.conf << EOF
[small]
name = "Small (1 cpu, 2 GB mem)"
cpus=1
mem-mb=1936
#name = "Medium (2 cpu, 4 GB mem)"
#[medium]
#mem-mb=3873
#[large]
#cpus=2
#name = "Large (4 cpu, 8 GB mem)"
#cpus=4
#mem-mb=7746
#[xlarge]
#name = "Extra Large (8 cpu, 16 GB mem)"
#cpus=8
#mem-mb=15493
EOF

else

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

cat > $PWB_CONFIG_DIR/launcher.slurm.profiles.conf<<EOF 
[*]
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurm.resources.conf<<EOF
[small]
name = "Small (1 cpu, 2 GB mem)"
cpus=1
mem-mb=1936
#name = "Medium (2 cpu, 4 GB mem)"
#[medium]
#mem-mb=3873
#[large]
#cpus=2
#name = "Large (4 cpu, 8 GB mem)"
#cpus=4
#mem-mb=7746
#[xlarge]
#name = "Extra Large (8 cpu, 16 GB mem)"
#cpus=8
#mem-mb=15493
EOF

fi

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
mkdir -p /home/renv
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
setfacl -R --set-file=$tmpfile /home/renv
rm -rf $tmpfile


cat << EOF > $PWB_CONFIG_DIR/database.conf
provider=postgresql
host=RSW_DB_HOST
database=pwb
port=5432
username=RSW_DB_USER
password=RSW_DB_PASS
connection-timeout-seconds=10
EOF

chmod 0600 $PWB_CONFIG_DIR/database.conf

# Setup crash handler
cat << EOF > $PWB_CONFIG_DIR/crash-handler.conf
crash-handling-enabled=1
crash-db-path=$SHARED_DATA/crash-dumps
EOF

mkdir -p $SHARED_DATA/crash-dumps
chmod 777 $SHARED_DATA/crash-dumps

cat << EOF > $PWB_BASE_DIR/scripts/rc.pwb 
#!/bin/bash

set -x 

exec > /var/log/rc.pwb.log
exec 2>&1

# Add stuff for increased performance 
export pwb_version=\`rstudio-server version | cut -d "-" -f 1 | sed 's/\.//g'\`

if [ \$pwb_version -lt 2023120 ] && \
        !( grep "worker_rlimit_nofile 4096" /usr/lib/rstudio-server/conf/rserver-http.conf >& /dev/null); then 
        sed -i 's/worker_connections.*/worker_connections   2048;/' /usr/lib/rstudio-server/conf/rserver-http.conf
        sed -i '/events.*/i worker_rlimit_nofile 4096;' /usr/lib/rstudio-server/conf/rserver-http.conf
fi

if (mount | grep login_nodes >&/dev/null) && [ ! -f /etc/head-node ]; then
    # we are on a login node and need to start the workbench processes 
    # but we need to make sure the config files are all there
    while true ; do if [ -f /opt/rstudio/etc/rstudio/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"
    if (BENCHMARK_SUPPORT); then 
        # symlink /opt/rstudio/rstudio-server into /usr/lib/rstudio-server 
        rm -rf /usr/lib/rstudio-server
        ln -s /opt/rstudio/rstudio-server /usr/lib 
    fi
    if [ ! -f /etc/systemd/system/rstudio-server.service.d/override.conf ]; then 
        # systemctl overrides
        for i in server launcher 
        do 
            mkdir -p /etc/systemd/system/rstudio-\$i.service.d
            echo -e "[Service]\nEnvironment=\"RSTUDIO_CONFIG_DIR=/opt/rstudio/etc/rstudio\"" > /etc/systemd/system/rstudio-\$i.service.d/override.conf
        done
        # We are on a login node and hence will need to enable rstudio-server and rstudio-launcher
        systemctl daemon-reload
        systemctl enable rstudio-server
        systemctl enable rstudio-launcher
        #rm -f /var/lib/rstudio-server/secure-cookie-key
        #rm -f /opt/rstudio/etc/rstudio/launcher.pub
        #rm -f /opt/rstudio/etc/rstudio/launcher.pem
        systemctl start rstudio-launcher
        systemctl start rstudio-server
        #rm -f /var/lib/rstudio-server/secure-cookie-key
        #systemctl restart rstudio-server 
        # Touch a file in /opt/rstudio to signal that workbench is running on this server
        touch /opt/rstudio/workbench-\`hostname\`.state
    fi    

    if [ -f /opt/rstudio/etc/rstudio/rserver.conf ] && [ ! -f /opt/rstudio/workbench-\`hostname\`.state ]; then 
        systemctl stop rstudio-server 
        systemctl stop rstudio-launcher
        systemctl start rstudio-launcher
        systemctl start rstudio-server 
        touch /opt/rstudio/workbench-\`hostname\`.state
    fi
    
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


EOF

chmod +x $PWB_BASE_DIR/scripts/rc.pwb 

if (SINGULARITY_SUPPORT); then
        cd /tmp && \
                git clone https://github.com/sol-eng/singularity-rstudio.git && \
                cd singularity-rstudio/data/r-session-complete &&
                export slurm_version=`/opt/slurm/bin/sinfo -V | cut -d " " -f 2` && 
                export pwb_version=`rstudio-server version | awk '{print \$1}' | sed 's/+/-/'` &&
                sed -i "s/SLURM_VERSION.*/SLURM_VERSION=$slurm_version/" build.env &&
                sed -i "s/PWB_VERSION.*/PWB_VERSION=$pwb_version/" build.env &&
                for i in `ls -d */ | sed 's#/##'`; do \
		        ( pushd $i && \
			singularity build --build-arg-file ../build.env $PWB_BASE_DIR/apptainer/$i.sif r-session-complete.sdef && \
                        popd ) & 
                        if [[ $(jobs -r -p | wc -l) -ge 2 ]]; then
                                wait -n
                        fi
                done

        # We also need to build the SPANK plugin for singularity

        cd /tmp/singularity-rstudio/slurm-singularity-exec/ && \
                sed -i "s#CONTAINER_PATH#$PWB_BASE_DIR/apptainer#" singularity-exec.conf.tmpl && \
                make && make install 

        # Uncomment singularity-image-directory

        sed -i -r '/^#sing/ s/.(.*)/\1/' $PWB_CONFIG_DIR/launcher.slurm.profiles.conf

        cat << EOF >> $PWB_CONFIG_DIR/launcher-env
SINGULARITY_BIND=/sys,/opt/slurm,/var/run/munge,/var/spool/slurmd,/etc/munge,/run/munge
EOF

fi

