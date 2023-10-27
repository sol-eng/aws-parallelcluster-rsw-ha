#!/bin/bash

# cf. https://docs.posit.co/resources/install-python/

if ( ! dpkg -l curl >& /dev/null); then 
apt-get update 
apt-get install -y curl
fi

if ( ! dpkg -l gdebi-core >& /dev/null); then 
apt-get update 
apt-get install -y gdebi
fi

for PYTHON_VERSION in $2
do
  curl -O https://cdn.rstudio.com/python/ubuntu-2004/pkgs/python-${PYTHON_VERSION}_1_amd64.deb
  gdebi -n python-${PYTHON_VERSION}_1_amd64.deb
  rm -f python-${PYTHON_VERSION}_1_amd64.deb
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

for PYTHON_VERSION in $2
do
  /opt/python/"${PYTHON_VERSION}"/bin/pip install --upgrade \
    pip setuptools wheel && \
  /opt/python/${PYTHON_VERSION}/bin/pip install \
    ipykernel
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
ln -s /opt/python/$3/bin/jupyter /usr/local/bin
ln -s /opt/python/$3/bin/python /usr/local/bin
ln -s /opt/python/$3/bin/python3 /usr/local/bin
