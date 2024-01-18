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
useradd -s /bin/bash -m -d /shared/rstudio --system --gid rstudio --uid 8787 rstudio
groupadd --system --gid 8788 rstudio-admins
groupadd --system --gid 8789 rstudio-superuser-admins
usermod -G rstudio-admins,rstudio-superuser-admins rstudio

# add super secure password  
echo -e "Testme1234\nTestme1234" | passwd rstudio



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

(crontab -l ; echo "0-59/1 * * * * /opt/rstudio/scripts/rc.pwb")| crontab -


## replace launcher with 2.15.x pre-release if not using 2023.12.0 daily

if [ `rstudio-server version | cut -d "+" -f 1 | sed 's/\.//g'` -lt 2023120 ]; then
    pushd /tmp && \ 
    curl -O https://cdn.rstudio.com/launcher/releases/bionic/launcher-bionic-amd64-2.15.1-5.tar.gz && \
    tar xvfz launcher-* -C /usr/lib/rstudio-server/bin  --strip-components=1 && \
    rm -f launcher-* && popd 
fi
