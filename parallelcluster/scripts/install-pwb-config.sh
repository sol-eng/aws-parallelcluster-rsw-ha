#!/bin/bash
#
# Head node OnNodeConfigured action (see config/cluster-config-wb.*.tmpl).
#
# Writes the complete Posit Workbench configuration to the shared
# /opt/rstudio EFS, registers the login nodes with the Pulumi-managed ALBs
# and drops /opt/rstudio/scripts/rc.pwb, which the per-minute cron job baked
# into the AMI runs on every login node to install and (re)start Workbench.
#
# Args: $1 PWB_VERSION  $2 HPC_DOMAIN  $3 HPC_HOST
# Placeholders wrapped in double @ signs are filled in by deploy.sh before upload.

set -x

exec > /var/log/install-pwb-config.log
exec 2>&1

SHARED_DIR=/opt

PWB_BASE_DIR=$SHARED_DIR/rstudio/

PWB_CONFIG_DIR=$PWB_BASE_DIR/etc/rstudio


mkdir -p $PWB_BASE_DIR/{scripts,apptainer}

mkdir -p $PWB_CONFIG_DIR

mkdir -p /home/rstudio/shared-storage

SHARED_DATA="/home/rstudio/shared-storage"

PWB_VERSION=$1

HPC_DOMAIN=$2

HPC_HOST=$3

# Label this node as head-node so we can detect it later
touch /etc/head-node

# Posit publishes Workbench builds for Ubuntu 22.04 (jammy) only; these are
# the supported packages for Ubuntu 24.04 (noble) as well.
PWB_DIST=jammy

# Workbench package for the login nodes (installed by config-login.sh)
pushd $PWB_BASE_DIR/scripts
curl -fsSLO https://s3.amazonaws.com/rstudio-ide-build/server/${PWB_DIST}/amd64/rstudio-workbench-${PWB_VERSION}-amd64.deb
popd

# Session components for the compute nodes, packed into a squashfs image on
# the shared EFS. Compute nodes loop-mount it read-only at
# /usr/lib/rstudio-server (config-compute.sh) instead of each node downloading
# and extracting the tarball. The image is written under a temporary name and
# moved into place, so a compute node never mounts a half-written file.
SQSH_DIR=$PWB_BASE_DIR/session-components
SQSH_FILE=$SQSH_DIR/rsw-session-${PWB_VERSION}.sqsh
mkdir -p $SQSH_DIR
if [ ! -f $SQSH_FILE ]; then
        command -v mksquashfs >/dev/null || apt-get install -y squashfs-tools
        session_tgz=$SQSH_DIR/rsp-session-${PWB_DIST}-${PWB_VERSION}-amd64.tar.gz
        curl -fsSL -o $session_tgz https://s3.amazonaws.com/rstudio-ide-build/session/${PWB_DIST}/amd64/rsp-session-${PWB_DIST}-${PWB_VERSION}-amd64.tar.gz
        session_tmp=$(mktemp -d)
        chmod 755 $session_tmp
        tar xzf $session_tgz -C $session_tmp --strip-components=1
        mksquashfs $session_tmp $SQSH_FILE.tmp -comp zstd -noappend -all-root
        mv -f $SQSH_FILE.tmp $SQSH_FILE
        rm -rf $session_tmp $session_tgz
fi

if ( ! grep "@@AD_DNS@@" /etc/hosts >& /dev/null ); then
        echo "@@AD_DNS@@ @@AD_DOMAIN@@" >> /etc/hosts
fi

# Demo admin user gets passwordless sudo
echo "posit0001   ALL=NOPASSWD: ALL" > /etc/sudoers.d/posit0001
chmod 0440 /etc/sudoers.d/posit0001

# Add SLURM integration

# wait until ELB is available and then set this to make sure workbench jobs are working

export AWS_DEFAULT_REGION=`cat /opt/parallelcluster/shared/cluster-config.yaml  | grep ^Region | awk '{print $2}'`

snap install yq

export PATH=$PATH:/snap/bin

cluster_name=`cat  /opt/parallelcluster/shared/cluster-config.yaml | yq eval '.Tags[] | select(.Key == "parallelcluster:cluster-name") | .Value'`
login_nodes_number=`cat /opt/parallelcluster/shared/cluster-config.yaml | yq .LoginNodes.Pools[].Count`

echo "login nodes": $login_nodes_number

# Give up waiting for AWS resources after this many seconds
WAIT_TIMEOUT=3600

# First, get the ARN of the login node NLB that ParallelCluster creates
elb=""
SECONDS=0
while true
do
        elb=`for i in $(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[].LoadBalancerArn'); do if ( aws elbv2 describe-tags --resource-arns "$i" | jq --arg cluster_name "$cluster_name" -ce '.TagDescriptions[].Tags[] | select( .Key == "parallelcluster:cluster-name" and .Value==$cluster_name)' > /dev/null); then echo $i; fi; done `
        if [ -n "$elb" ]; then break; fi
        if [ $SECONDS -ge $WAIT_TIMEOUT ]; then echo "ERROR: login node load balancer not found"; exit 1; fi
        sleep 10
done

# ELB URL
elb_url=`aws elbv2 describe-load-balancers --load-balancer-arns=$elb | jq -r '.[] | .[] | .DNSName'`

# Target Group ARN
target_arn=`aws elbv2 describe-target-groups --load-balancer-arn=$elb --query TargetGroups[].TargetGroupArn | jq -r '.[]'`

# EC2 IDs attached to Target Group
ec2_ids=""
SECONDS=0
while true
do
        ec2_ids=`aws elbv2 describe-target-health --target-group-arn $target_arn --query 'TargetHealthDescriptions[*].Target.Id' | jq -r '.[]'`
        nr_ids=`set -- $ec2_ids && echo $#`
        if [ "$nr_ids" == "$login_nodes_number" ]; then break; fi
        if [ $SECONDS -ge $WAIT_TIMEOUT ]; then echo "ERROR: only $nr_ids of $login_nodes_number login nodes registered"; exit 1; fi
        sleep 10
done

# Resolve EC2 IDs into ip addresses and add them as HPC_DOMAIN hostnames into nodes file
ctr=0
ec2_ips=""
echo "#---do not modify below ---" > $PWB_CONFIG_DIR/nodes
for i in $ec2_ids;
        do
                ctr=$(($ctr+1))
                ip=`aws ec2 describe-instances --filters "Name=instance-id,Values=$i" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text`
                ec2_ips="$ip $ec2_ips"
                echo "$ip node${ctr} node${ctr}.${HPC_DOMAIN}" >> $PWB_CONFIG_DIR/nodes
         done

# Append nodes file to /etc/hosts
cat  $PWB_CONFIG_DIR/nodes >> /etc/hosts

# Register the login nodes (port 8787) with the internal and external ALB
# target groups created by Pulumi (pwb-alb-tg-{int,ext}-<cluster_name>)
for tg in int ext
do
        tg_arn=$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName, 'pwb-alb-tg-$tg') && contains(TargetGroupName, '$cluster_name')].TargetGroupArn" --output text)
        if [ -z "$tg_arn" ]; then echo "WARNING: no pwb-alb-tg-$tg target group for $cluster_name"; continue; fi
        for ip in $ec2_ips
        do
                aws elbv2 register-targets --target-group-arn "$tg_arn" --targets Id="$ip",Port=8787
        done
done



# secure-cookie-key (a UUID generated by Pulumi)
echo "@@SECURE_COOKIE_KEY@@" > $PWB_CONFIG_DIR/secure-cookie-key
chmod 0600 $PWB_CONFIG_DIR/secure-cookie-key

cat > $PWB_CONFIG_DIR/launcher-env << EOF
RSTUDIO_DISABLE_PACKAGE_INSTALL_PROMPT=yes
SLURM_CONF=/opt/slurm/etc/slurm.conf
EOF

cat > $PWB_CONFIG_DIR/logging.conf << EOF
[*]
log-level=info
logger-type=file
rotate=0
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
EOF

# Sessions on compute nodes call back into Workbench. Without SSL on the
# login nodes this goes through the internal HTTPS ALB (Route53 name from Pulumi).
if [ "@@SSL@@" = true ]
then
        echo "launcher-sessions-callback-address=https://$HPC_HOST.$HPC_DOMAIN" >> $PWB_CONFIG_DIR/rserver.conf
else
        echo "launcher-sessions-callback-address=https://@@PWB_URL_INT@@" >> $PWB_CONFIG_DIR/rserver.conf
fi

cat >> $PWB_CONFIG_DIR/rserver.conf << EOF

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
secure-cookie-key-file=/etc/rstudio/secure-cookie-key

# scalability
auth-timeout-minutes=120
www-thread-pool-size=8

# performance optimisations
rsession-proxy-max-wait-secs=30

# Workbench API
# Enable user level tokens
workbench-api-enabled=1

# Enable admin level tokens
workbench-api-admin-enabled=1

# Enable super-admin level tokens
workbench-api-super-admin-enabled=1

# Enable audited jobs
audited-jobs=1
audited-jobs-storage-path=/home/rstudio/shared-storage/audited-jobs


EOF

if [ "@@LOCAL@@" = true ]
then
cat >> $PWB_CONFIG_DIR/rserver.conf << EOF

# multiple launchers
launcher-sessions-clusters=local,slurminteractive
launcher-adhoc-clusters=slurmbatch
EOF
else
cat >> $PWB_CONFIG_DIR/rserver.conf << EOF

# multiple launchers
launcher-sessions-clusters=slurminteractive
launcher-adhoc-clusters=slurmbatch
EOF
fi

# Positron support
cat << EOF > $PWB_CONFIG_DIR/positron.conf
enabled=1
exe=/usr/lib/rstudio-server/bin/positron-server/bin/positron-server
EOF

cat << EOF > $PWB_CONFIG_DIR/positron.extensions.conf
posit.shiny
posit.publisher
EOF


mkdir -p $SHARED_DATA/head-node/{audit-data,monitor-data}
chown -R rstudio-server $SHARED_DATA/head-node/

if [ "@@SSL@@" = true ]
then
    cat << EOF >> $PWB_CONFIG_DIR/rserver.conf

# Ssl Certificate
ssl-enabled=1
ssl-certificate=$PWB_BASE_DIR/etc/$HPC_DOMAIN.crt
ssl-certificate-key=$PWB_BASE_DIR/etc/$HPC_DOMAIN.key
EOF

        aws s3 cp s3://@@S3_PREFIX@@/$HPC_DOMAIN.crt $PWB_BASE_DIR/etc
        aws s3 cp s3://@@S3_PREFIX@@/$HPC_DOMAIN.key $PWB_BASE_DIR/etc
        chmod 0600 $PWB_BASE_DIR/etc/$HPC_DOMAIN.key
fi

if [ "@@EASYBUILD_SUPPORT@@" = true ]
then

    # get rid of modules.sh (left-over from environment-modules)
    rm -rf /etc/profile.d/modules.sh

    #disable r-versions-scan
    sed -i 's/#r-versions-scan=.*/r-versions-scan=0/' $PWB_CONFIG_DIR/rserver.conf

    # add modules-bin-path
    echo "modules-bin-path=$PWB_CONFIG_DIR/modules.sh" >> $PWB_CONFIG_DIR/rserver.conf

    # create wrapper script to be used as modules-bin-path
    cat << EOF > $PWB_CONFIG_DIR/modules.sh
#!/bin/bash
. /usr/share/lmod/lmod/init/sh
export MODULEPATH=/opt/apps/easybuild/modules/all
EOF

    # add entries for each version to r-versions
    for i in 4.0.5 4.1.2 4.2.1
    do
        echo "Module: R/$i-foss-2022a" >> $PWB_CONFIG_DIR/r-versions
        echo "Label: EasyBuild R $i" >> $PWB_CONFIG_DIR/r-versions
        echo "" >> $PWB_CONFIG_DIR/r-versions
   done
fi

cat > $PWB_CONFIG_DIR/launcher.conf<<EOF
[server]
address=0.0.0.0
port=5559
server-user=rstudio-server
admin-group=rstudio-server
authorization-enabled=1
thread-pool-size=4
enable-debug-logging=1
EOF

if [ "@@LOCAL@@" = true ]
then
    echo "enable-cgroups=1" >>  $PWB_CONFIG_DIR/launcher.conf
fi

cat >> $PWB_CONFIG_DIR/launcher.conf<<EOF

[cluster]
name=slurminteractive
type=Slurm
config-file=/etc/rstudio/launcher.slurminteractive.conf

[cluster]
name=slurmbatch
type=Slurm
config-file=/etc/rstudio/launcher.slurmbatch.conf
EOF

if [ "@@LOCAL@@" = true ]
then
cat >> $PWB_CONFIG_DIR/launcher.conf<<EOF

[cluster]
name=local
type=Local
EOF
fi

mkdir -p $PWB_CONFIG_DIR/apptainer

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.conf << EOF
# Enable debugging
enable-debug-logging=1

# Basic configuration
slurm-service-user=slurm
slurm-bin-path=/opt/slurm/bin

# GPU specifics
enable-gpus=1
gpu-types=t4

# User/group and resource profiles
profile-config=/etc/rstudio/launcher.slurminteractive.profiles.conf
resource-profile-config=/etc/rstudio/launcher.slurminteractive.resources.conf

EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.conf << EOF
# Enable debugging
enable-debug-logging=1

# Basic configuration
slurm-service-user=slurm
slurm-bin-path=/opt/slurm/bin

# GPU specifics
enable-gpus=1
gpu-types=t4

# User/group and resource profiles
profile-config=/etc/rstudio/launcher.slurmbatch.profiles.conf
resource-profile-config=/etc/rstudio/launcher.slurmbatch.resources.conf

EOF

if [ "@@LOCAL@@" = true ]
then
cat > $PWB_CONFIG_DIR/launcher.local.conf << EOF
scratch-path=/home/rstudio/shared-storage/Local
load-balancer-preference=nfs
EOF

cat > $PWB_CONFIG_DIR/launcher.local.profiles.conf << EOF
[*]
max-cpus=4
max-mem-mb=15000
EOF

cat > $PWB_CONFIG_DIR/launcher.local.resources.conf<<EOF
# memory limits sized for t3.xlarge (4 vCPU, 16 GB) nodes
[small]
name = "Small (1 cpu, 1 GB mem)"
cpus=1
mem-mb=899
[medium]
name = "Medium (2 cpu, 4 GB mem)"
cpus=2
mem-mb=3873
[large]
name = "Large (4 cpu, 8 GB mem)"
cpus=4
mem-mb=7746

EOF

fi


if [ "@@SINGULARITY_SUPPORT@@" = true ]
then
                echo -e "# Default GPU brand\ndefault-gpu-brand=nvidia\n" >> $PWB_CONFIG_DIR/launcher.slurmbatch.conf
                echo -e "# Default GPU brand\ndefault-gpu-brand=nvidia\n" >> $PWB_CONFIG_DIR/launcher.slurminteractive.conf
fi

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.profiles.conf<<EOF
[*]
allowed-partitions=interactive,gpu
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.profiles.conf<<EOF
[*]
allowed-partitions=all,gpu
#singularity-image-directory=${PWB_BASE_DIR}/apptainer
#default-mem-mb=512
#default-cpus=4
#max-cpus=2
#max-mem-mb=1024
EOF

cat > $PWB_CONFIG_DIR/launcher.slurminteractive.resources.conf<<EOF
# memory limits sized for t3.xlarge (4 vCPU, 16 GB) nodes
[small]
name = "Small (1 cpu, 1 GB mem)"
cpus=1
mem-mb=899
[medium]
name = "Medium (2 cpu, 4 GB mem)"
cpus=2
mem-mb=3873
[large]
name = "Large (4 cpu, 8 GB mem)"
cpus=4
mem-mb=7746

EOF

cat > $PWB_CONFIG_DIR/launcher.slurmbatch.resources.conf<<EOF
# memory limits sized for t3.xlarge (4 vCPU, 16 GB) nodes
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

if [ "@@BENCHMARK_SUPPORT@@" = true ]
then
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
exe=/usr/lib/rstudio-server/bin/pwb-code-server/bin/code-server
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


cat << 'EOF' > $PWB_CONFIG_DIR/database.conf
provider=postgresql
host=@@RSW_DB_HOST@@
database=pwb
port=5432
username=@@RSW_DB_USER@@
password=@@RSW_DB_PASS@@
connection-timeout-seconds=10
EOF

chmod 0600 $PWB_CONFIG_DIR/database.conf

cat << 'EOF' > $PWB_CONFIG_DIR/audit-database.conf
provider=postgresql
host=@@RSW_AUDIT_DB_HOST@@
database=audit
port=5432
username=@@RSW_AUDIT_DB_USER@@
password=@@RSW_AUDIT_DB_PASS@@
connection-timeout-seconds=10
EOF

chmod 0600 $PWB_CONFIG_DIR/audit-database.conf

# Setup crash handler
cat << EOF > $PWB_CONFIG_DIR/crash-handler.conf
crash-handling-enabled=1
crash-db-path=$SHARED_DATA/crash-dumps
EOF

mkdir -p $SHARED_DATA/crash-dumps
chmod 777 $SHARED_DATA/crash-dumps

# rc.pwb: run every minute by cron on the login nodes (installed by
# config-login.sh). Restarts Workbench on a login node whenever its
# /opt/rstudio/workbench-<hostname>.state file is removed.
cat << EOF > $PWB_BASE_DIR/scripts/rc.pwb
#!/bin/bash

set -x

exec >> /var/log/rc.pwb.log
exec 2>&1

echo "----"
echo ""
echo "Running rc.pwb on \$(hostname)"
echo "Date: \$(date)"
echo ""
echo "----"
echo ""

# Only on login nodes, and only once config-login.sh (OnNodeConfigured) is done
if (mount | grep login_nodes >&/dev/null) && [ ! -f /etc/head-node ] && [ -f /etc/login-node-is-setup ]; then
        if [ -f /opt/rstudio/etc/rstudio/rserver.conf ] && [ ! -f /opt/rstudio/workbench-\`hostname\`.state ]; then
                # Something wants us to restart so let's do it
                systemctl stop rstudio-server
                systemctl stop rstudio-launcher
                killall apache2
                logrotate -f /etc/logrotate.d/rstudio
                systemctl start rstudio-launcher
                systemctl start rstudio-server
                touch /opt/rstudio/workbench-\`hostname\`.state
        fi
fi
EOF

chmod +x $PWB_BASE_DIR/scripts/rc.pwb


if [ "@@SINGULARITY_SUPPORT@@" = true ]
then
        # Container images are not built here: copy your .sif images (e.g.
        # converted from rstudio/r-session-complete) into $PWB_BASE_DIR/apptainer
        # (singularity-image-directory). Apptainer itself comes from the custom
        # AMI or is installed on the compute nodes by config-compute.sh.

        # Build tools for the SPANK plugin (not in the official ParallelCluster AMI)
        for pkg in git cmake g++ make; do
                command -v $pkg >/dev/null || NEED_PKGS="$NEED_PKGS $pkg"
        done
        if [ -n "$NEED_PKGS" ]; then
                apt-get -o DPkg::Lock::Timeout=300 update
                apt-get -o DPkg::Lock::Timeout=300 install -y $NEED_PKGS
        fi

        rm -rf /tmp/singularity-rstudio
        git clone --depth 1 https://github.com/sol-eng/singularity-rstudio.git /tmp/singularity-rstudio

        # SPANK plugin so Slurm jobs can run inside the containers

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

