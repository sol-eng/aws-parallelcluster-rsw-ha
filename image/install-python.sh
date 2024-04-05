#!/bin/bash

# cf. https://docs.posit.co/resources/install-python/

set -x 

exec > /opt/python-install.log
exec 2>&1

PYTHON_VERSION_LIST=${@: 2:$#}
PYTHON_VERSION_DEFAULT=${@: 1:1}

echo "PYTHON_VERSION_LIST": $PYTHON_VERSION_LIST
echo "PYTHON_VERSION_DEFAULT": $PYTHON_VERSION_DEFAULT

if [ $OS=="ubuntu" ]; then 
  if ( ! dpkg -l curl >& /dev/null); then 
  apt-get update 
  apt-get install -y curl
  fi

  if ( ! dpkg -l gdebi-core >& /dev/null); then 
  apt-get update 
  apt-get install -y gdebi
  fi
else
  if ( ! rpm -qi epel-release >& /dev/null); then)
    yum -y install epel-release
    crb enable
  fi
fi

for PYTHON_VERSION in ${PYTHON_VERSION_LIST}
do
  if [ $OS=="ubuntu" ]; then 
    curl -O https://cdn.rstudio.com/python/ubuntu-$OSNUM/pkgs/python-${PYTHON_VERSION}_1_amd64.deb
    gdebi -n python-${PYTHON_VERSION}_1_amd64.deb
    rm -f python-${PYTHON_VERSION}_1_amd64.deb
  else
    if [ $OSNUM=="8" ]; then 
      URL=https://cdn.rstudio.com/python/centos-$OSNUM/pkgs/python-${PYTHON_VERSION}-1-1.x86_64.rpm
    else
      URL=https://cdn.rstudio.com/python/rhel-$OSNUM/pkgs/python-${PYTHON_VERSION}-1-1.x86_64.rpm
    fi
    yum -y install $URL
done

# Configure Python versions to have 
#  - upgraded pip 
#  - configure pip to use posit package manager 
#  - preinstalling packages needed for the integration with other tools (e.g Connect) 
# Note: Install will run in parallel to speed up things

cat << EOF > /etc/pip.conf
[global]
index-url = https://packagemanager.rstudio.com/pypi/latest/simple
EOF

for PYTHON_VERSION in ${PYTHON_VERSION_LIST}
do
  /opt/python/${PYTHON_VERSION}/bin/pip install --upgrade \
    pip setuptools wheel && \
  /opt/python/${PYTHON_VERSION}/bin/pip install \
    ipykernel \
    jupyter \
    jupyterlab \
    rsconnect_jupyter \
    rsconnect_python \
    rsp_jupyter \
    workbench_jupyterlab \
    && /opt/python/${PYTHON_VERSION}/bin/jupyter-nbextension install --sys-prefix --py rsp_jupyter \
    && /opt/python/${PYTHON_VERSION}/bin/jupyter-nbextension enable --sys-prefix --py rsp_jupyter \
    && /opt/python/${PYTHON_VERSION}/bin/jupyter-nbextension install --sys-prefix --py rsconnect_jupyter \
    && /opt/python/${PYTHON_VERSION}/bin/jupyter-nbextension enable --sys-prefix --py rsconnect_jupyter \
    && /opt/python/${PYTHON_VERSION}/bin/jupyter-serverextension enable --sys-prefix --py rsconnect_jupyter \
    && /opt/python/${PYTHON_VERSION}/bin/python -m ipykernel install --name py${PYTHON_VERSION} --display-name "Python ${PYTHON_VERSION}" & 
done
wait
 
# Use default version to point to jupyter and python 
if [ ! -z ${PYTHON_VERSION_DEFAULT} ]; then
  ln -s /opt/python/${PYTHON_VERSION_DEFAULT}/bin/jupyter /usr/local/bin
  ln -s /opt/python/${PYTHON_VERSION_DEFAULT}/bin/python /usr/local/bin
  ln -s /opt/python/${PYTHON_VERSION_DEFAULT}/bin/python3 /usr/local/bin
fi
