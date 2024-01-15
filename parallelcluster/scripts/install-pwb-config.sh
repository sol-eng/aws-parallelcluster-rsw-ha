#!/bin/bash

# This script is run on the head node, we temporarily need to mount the shared directory 
# for the shared_login_nodes in order to populate the rstudio config

SHARED_DIR=/opt/parallelcluster/shared_login_nodes

mount `mount  | grep slurm | awk '{print $1}' | \
        sed "s#/opt/slurm#$SHARED_DIR#"`\
        $SHARED_DIR


PWB_BASE_DIR=$SHARED_DIR/rstudio/

PWB_CONFIG_DIR=$PWB_BASE_DIR/etc/rstudio

mkdir -p $PWB_BASE_DIR/{etc/rstudio,shared-storage,scripts,apptainer}


# Add SLURM integration 
myip=`curl http://checkip.amazonaws.com`

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
server-shared-storage-path=${PWB_BASE_DIR}/shared-storage

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

# secure cookie key
secure-cookie-key-file=${PWB_CONFIG_DIR}/secure-cookie-key
EOF

mkdir -p ${PWB_BASE_DIR}/shared-data/head-node/{audit-data,monitor-data}
chown -R rstudio-server ${PWB_BASE_DIR}/shared-data/head-node/


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
name=Slurm
type=Slurm

#[cluster]
#name=Local
#type=Local

EOF

mkdir -p $PWB_CONFIG_DIR/apptainer

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
host=DB_HOST
database=pwb
port=5432
username=DB_USER
password=DB_PASS
connection-timeout-seconds=10
EOF

chmod 0600 $PWB_CONFIG_DIR/database.conf

# Setup crash handler
cat << EOF > $PWB_CONFIG_DIR/crash-handler.conf
crash-handling-enabled=1
crash-db-path=/opt/parallelcluster/shared_login_nodes/rstudio/shared-storage/crash-dumps
EOF

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

if (mount | grep login_nodes >&/dev/null); then
    # we are on a login node and need to start the workbench processes 
    # but we need to make sure the config files are all there
    while true ; do if [ -f /opt/parallelcluster/shared_login_nodes/rstudio/etc/rstudio/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"
    if [ ! -f /etc/systemd/system/rstudio-server.service.d/override.conf ]; then 
        # systemctl overrides
        for i in server launcher 
        do 
            mkdir -p /etc/systemd/system/rstudio-\$i.service.d
            echo -e "[Service]\nEnvironment=\"RSTUDIO_CONFIG_DIR=/opt/parallelcluster/shared_login_nodes/rstudio/etc/rstudio\"" > /etc/systemd/system/rstudio-\$i.service.d/override.conf
        done
        # We are on a login node and hence will need to enable rstudio-server and rstudio-launcher
        systemctl daemon-reload
        systemctl enable rstudio-server
        systemctl enable rstudio-launcher
        #rm -f /var/lib/rstudio-server/secure-cookie-key
        #rm -f /opt/parallelcluster/shared_login_nodes/rstudio/etc/rstudio/launcher.pub
        #rm -f /opt/parallelcluster/shared_login_nodes/rstudio/etc/rstudio/launcher.pem
        systemctl start rstudio-launcher
        systemctl start rstudio-server
        #rm -f /var/lib/rstudio-server/secure-cookie-key
        #systemctl restart rstudio-server 
    fi    
    
fi

if ( ! grep AD_DNS /etc/hosts >& /dev/null ); then 
        echo "AD_DNS pwb.posit.co" >> /etc/hosts
fi

if ( ! grep posit0001 /etc/sudoers >& /dev/null ); then 
        echo "posit0001   ALL=NOPASSWD: ALL" >> /etc/sudoers
fi



EOF

chmod +x $PWB_BASE_DIR/scripts/rc.pwb 

if (SINGULARITY_SUPPORT); then
        # we're building singularity containers here 
        # since PPM sometimes behaves rather funny (package download failure) we run the build until it succeeds. 
        cd /tmp && \
                git clone https://github.com/sol-eng/singularity-rstudio.git && \
                cd singularity-rstudio/data/r-session-complete &&
                export slurm_version=`/opt/slurm/bin/sinfo -V | cut -d " " -f 2` && 
                export pwb_version=`rstudio-server version | awk '{print \$1}' | sed 's/+/-/'` &&
                sed -i "s/SLURM_VERSION.*/SLURM_VERSION=$slurm_version/" build.env &&
                sed -i "s/PWB_VERSION.*/PWB_VERSION=$pwb_version/" build.env &&
                for i in `ls | grep -v build.env`; do \
		        pushd $i && \
			ctr=0
		        while true ; do ctr=$(( $ctr+1 )) singularity build --build-arg-file ../build.env $PWB_BASE_DIR/apptainer/$i.sif r-session-complete.sdef ; if [ $? -eq 0 ] || [ $ctr -gt 3 ]; then break; fi; done
                        popd
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

umount $SHARED_DIR
