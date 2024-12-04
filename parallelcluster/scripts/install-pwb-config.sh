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

PWB_VERSION=$1

# Label this node as head-node so we can detect it later
touch /etc/head-node

# Download session components and store them in $PWB_BASE_DIR/scripts

pushd $PWB_BASE_DIR/scripts
curl -O https://s3.amazonaws.com/rstudio-ide-build/session/jammy/amd64/rsp-session-jammy-${PWB_VERSION}-amd64.tar.gz
curl -O https://s3.amazonaws.com/rstudio-ide-build/server/jammy/amd64/rstudio-workbench-${PWB_VERSION}-amd64.deb 
popd

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
chmod 0600 $PWB_CONFIG_DIR/etc/rstudio/secure-cookie-key

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

# scalability 
auth-timeout-minutes=120
www-thread-pool-size=8

# multiple launchers
launcher-sessions-clusters=slurminteractive
launcher-adhoc-clusters=slurmbatch

# performance optimisations
rsession-proxy-max-wait-secs=30
EOF

mkdir -p $SHARED_DATA/head-node/{audit-data,monitor-data}
chown -R rstudio-server $SHARED_DATA/head-node/


# Add stuff for increased performance 
export pwb_version=`rstudio-server version | cut -d "-" -f 1 | sed 's/\.//g'`
if [ $pwb_version -ge 2023120 ]; then 
        cat > $PWB_CONFIG_DIR/nginx.worker.conf << EOF
worker_processes 1;

worker_rlimit_nofile 8192;

events {
    worker_connections  4096;
}
EOF
fi

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

mkdir -p $PWB_CONFIG_DIR/apptainer

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
profile-config=$PWB_CONFIG_DIR/launcher.slurminteractive.profiles.conf
resource-profile-config=$PWB_CONFIG_DIR/launcher.slurminteractive.resources.conf

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
profile-config=$PWB_CONFIG_DIR/launcher.slurmbatch.profiles.conf
resource-profile-config=$PWB_CONFIG_DIR/launcher.slurmbatch.resources.conf

EOF

if (SINGULARITY_SUPPORT); then 
        my_pwb_version=`rstudio-server version | cut -d "+" -f 1 | sed 's/\.//g'`

        if [[ $my_pwb_version =~ "daily" ]]; then 
        my_pwb_version=${my_pwb_version/-daily/}
        fi

        if [ $my_pwb_version -gt 2024000 ]; then
                echo -e "# Default GPU brand\ndefault-gpu-brand=nvidia\n" >> $PWB_CONFIG_DIR/launcher.slurmbatch.conf
                echo -e "# Default GPU brand\ndefault-gpu-brand=nvidia\n" >> $PWB_CONFIG_DIR/launcher.slurminteractive.conf
        fi
fi

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.profiles.conf<<EOF 
[*]
allowed-partitions=interactive
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.profiles.conf<<EOF 
[*]
allowed-partitions=all
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.resources.conf<<EOF
# memory limits calculated based on 90% of total t3.xlarge memory
[small]
name = "Small (1 cpu, 1 GB mem)"
cpus=1
mem-mb=899
[medium]
name = "Medium (2 cpu, 2 GB mem)"
cpus=2
mem-mb=3873
[large]
name = "Large (4 cpu, 4 GB mem)"
cpus=4
mem-mb=7746

EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.resources.conf<<EOF
# memory limits calculated based on 90% of total t3.xlarge memory
[small]
name = "Small (1 cpu, 4 GB mem)"
cpus=1
mem-mb=3596
[medium]
name = "Medium (2 cpu, 8 GB mem)"
cpus=2
mem-mb=7194
[large]
name = "Large (4 cpu, 16 GB mem)"
cpus=4
mem-mb=14386

EOF

if (BENCHMARK_SUPPORT); then 
cat > $PWB_CONFIG_DIR/launcher.slurminteractive.resources.conf<<EOF
[small]
name = "Small (1 cpu, 1 GB mem)"
cpus=1
mem-mb=968

EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.resources.conf<<EOF
[small]
name = "Small (1 cpu, 1 GB mem)"
cpus=1
mem-mb=968

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
        # yay - we are on a login node 
        if [ ! -f /etc/login-node-is-setup ]; then
                #  we have not set up workbench so let's do it
                touch /etc/login-node-is-setup
                $PWB_BASE_DIR/scripts/config-login.sh $PWB_CONFIG_DIR $PWB_VERSION
        fi

        if [ -f /opt/rstudio/etc/rstudio/rserver.conf ] && [ ! -f /opt/rstudio/workbench-\`hostname\`.state ]; then 
                # Something wants us to restart so let's do it
                systemctl stop rstudio-server 
                systemctl stop rstudio-launcher
                killall apache2
                rm -rf /var/log/rstudio
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

if ( ! mount | grep \/scratch ); then 
        # create scratch folder as part of EFS fs
        mkdir -p /scratch /opt/rstudio/scratch 
        efsmount=`cat /etc/fstab  | grep rstudio | awk '{print $1}'`
        mount ${efsmount}scratch /scratch
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
                cmake -S . -B build -D CMAKE_INSTALL_PREFIX=/opt/slurm -DINSTALL_PLUGSTACK_CONF=ON && \
                cmake --build build --target install

        cat << EOF > /opt/slurm/etc/plugstack.conf
include /opt/slurm/etc/plugstack.conf.d/*.conf
EOF

        # Uncomment singularity-image-directory

        sed -i -r '/^#sing/ s/.(.*)/\1/' $PWB_CONFIG_DIR/launcher.*.profiles.conf

        cat << EOF >> $PWB_CONFIG_DIR/launcher-env
APPTAINER_BIND=/scratch,/opt/slurm/etc,/opt/slurm/libexec,/var/spool/slurmd,/var/run/munge
SINGULARITY_BIND=/scratch,/opt/slurm/etc,/opt/slurm/libexec,/var/spool/slurmd,/var/run/munge
EOF

fi

