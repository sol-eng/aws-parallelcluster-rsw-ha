#!/bin/bash
#
# Local "rstudio" service user and the Workbench admin groups, plus the
# packages needed to join the nodes to the SimpleAD domain (sssd, realmd,
# krb5) and adcli built from source.

export DEBIAN_FRONTEND=noninteractive

# Add sample user
groupadd --system --gid 8787 rstudio
useradd -s /bin/bash -d /shared/rstudio --system --gid rstudio --uid 8787 rstudio
groupadd --system --gid 8788 rstudio-admins
groupadd --system --gid 8789 rstudio-superuser-admins
usermod -G rstudio-admins,rstudio-superuser-admins rstudio

apt-get update
apt-get install -y libpam-runtime
# automatically create home directories on first login
pam-auth-update --enable mkhomedir

apt-get install -y git automake libtool libkrb5-dev libldap2-dev libsasl2-dev net-tools\
                make expect sssd realmd krb5-user samba-common packagekit pamtester
git clone -b 0.9.2 https://gitlab.freedesktop.org/realmd/adcli.git && \
    pushd adcli && \
    ./autogen.sh --disable-doc && \
    make -j $(( 2*`nproc` ))  && \
    make install && \
    popd && \
    rm -rf adcli


