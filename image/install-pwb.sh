# Install Posit Workbench 

PWB_VERSION=$1

# Add rstudio-server user and group 
groupadd --system --gid 900 rstudio-server
useradd -s /bin/bash -m --system --gid rstudio-server --uid 900 rstudio-server

# Install software

if ( ! dpkg -l curl >& /dev/null); then 
apt-get update 
apt-get install -y curl
fi

if ( ! dpkg -l gdebi-core >& /dev/null); then 
apt-get update 
apt-get install -y gdebi
fi

curl -O https://s3.amazonaws.com/rstudio-ide-build/server/focal/amd64/rstudio-workbench-${PWB_VERSION}-amd64.deb 
gdebi -n rstudio-workbench-${PWB_VERSION}-amd64.deb
rm -f rstudio-workbench-${PWB_VERSION}-amd64.deb







# Add sample user and groups, make rstudio part of admins and superuseradmin

groupadd --system --gid 8787 rstudio
useradd -s /bin/bash -m -d /data/rstudio --system --gid rstudio --uid 8787 rstudio
groupadd --system --gid 8788 rstudio-admins
groupadd --system --gid 8789 rstudio-superuser-admins
usermod -G rstudio-admins,rstudio-superuser-admins rstudio

# add super secure password  
echo -e "rstudio\nrstudio" | passwd rstudio



systemctl daemon-reload
rstudio-server stop
rstudio-launcher stop

# disable rstudio-server and rstudio-launcher in the image 

systemctl disable rstudio-server
systemctl disable rstudio-launcher

# Install VSCode based on the PWB version.
if ( rstudio-server | grep configure-vs-code ); then 
    rstudio-server configure-vs-code 
    rstudio-server install-vs-code-ext
    else 
    rstudio-server install-vs-code /opt/rstudio/vscode/
fi

VSCODE_EXTDIR=/usr/local/rstudio/code-server

mkdir -p /usr/local/rstudio/code-server
chmod a+rx /usr/local/rstudio/code-server

for extension in quarto.quarto \
        REditorSupport.r@2.6.1 \
        ms-python.python@2022.10.1 \
        /usr/lib/rstudio-server/bin/vscode-workbench-ext/rstudio-workbench.vsix  
do
   /usr/lib/rstudio-server/bin/code-server/bin/code-server --extensions-dir=$VSCODE_EXTDIR \
                        --install-extension $extension
done

chmod a+rx /usr/local/rstudio/code-server

rm -f /etc/rstudio

# Create rc.local file to determine which services to start

cat << EOF > /etc/rc.pwb 
#!/bin/bash

set -x 

exec > /var/log/rc.pwb.log
exec 2>&1

if (mount | grep slurm >&/dev/null && ! mount | grep rstudio >&/dev/null); then
    # we are not on the head node and need to mount /opt/rstudio
    mkdir -p /opt/rstudio
    grep slurm /etc/fstab | sed 's#/opt/slurm#/opt/rstudio#g' | sudo tee -a /etc/fstab
    mount -a
fi

if (mount | grep login_node >&/dev/null);  then 
    # we are on a login node and need to start the workbench processes 
    # but we need to make sure the config files are all there

    while true ; do if [ -f /opt/rstudio/etc/rstudio/rserver.conf ]; then break; fi; sleep 1; done ; echo "PWB config files found !"
    if [ ! -f /etc/systemd/system/rstudio-server.service.d ]; then 
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
        systemctl start rstudio-launcher
        systemctl start rstudio-server
    fi    
fi

EOF

chmod +x /etc/rc.pwb

cat << EOF > /lib/systemd/system/pwb-script.service 
[Unit]
Description=Run PWB check

[Service]
Restart=always
RestartSec=60s
ExecStart=/bin/bash /etc/rc.pwb

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pwb-script