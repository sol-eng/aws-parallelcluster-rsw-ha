# Add sample user 
groupadd --system --gid 8787 rstudio
useradd -s /bin/bash -d /data/rstudio --system --gid rstudio --uid 8787 rstudio
groupadd --system --gid 8788 rstudio-admins
groupadd --system --gid 8789 rstudio-superuser-admins
usermod -G rstudio-admins,rstudio-superuser-admins rstudio
 
echo -e "rstudio\nrstudio" | passwd rstudio

# automatically create home-directories with directories strictly only accessible by user. 
echo "session required	pam_mkhomedir.so skel=/etc/skel umask=0077" >> /etc/pam.d/common-session

apt-get update 
apt install -y git automake libtool libkrb5-dev libldap2-dev libsasl2-dev net-tools\
                make expect sssd realmd krb5-user samba-common packagekit pamtester
git clone -b 0.9.2 https://gitlab.freedesktop.org/realmd/adcli.git && \
    pushd adcli && \
    ./autogen.sh --disable-doc && \
    make -j $(( 2*`nproc` ))  && \
    sudo make install && \
    popd && \
    rm -rf adcli 

    
