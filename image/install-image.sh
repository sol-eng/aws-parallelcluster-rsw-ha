#!/bin/bash
#
# Entry point of the ImageBuilder script component (see image-config.yaml).
# Downloads the individual install-*.sh scripts from S3 and runs them.
# All software versions baked into the AMI are pinned here.

R_VERSION_LIST="4.6.0 4.5.2 4.4.3 4.3.3 4.2.3"
R_VERSION_DEFAULT=4.6.0

PYTHON_VERSION_LIST="3.13.11 3.12.12 3.11.14 3.10.19"
PYTHON_VERSION_DEFAULT=3.13.11

APPTAINER_VERSION="1.4.5"

QUARTO_VERSION="1.8.27"

FAILED=""

function setup_something() {
# $1 - script to be run
# $2... - parameters
aws s3 cp "s3://BUCKETNAME/image/$1" /tmp
if ! bash "/tmp/$1" "${@:2}"; then
  echo "WARNING: $1 exited with an error"
  FAILED="$FAILED $1"
fi
rm -f "/tmp/$1"
}

# Update all packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Local rstudio user/groups, mkhomedir, sssd/realmd and adcli for AD integration
setup_something install-dummy.sh

# Install R version(s)
setup_something install-r.sh $R_VERSION_DEFAULT "$R_VERSION_LIST"

# Install Python version(s)
setup_something install-python.sh $PYTHON_VERSION_DEFAULT "$PYTHON_VERSION_LIST"

# Install Quarto
setup_something install-quarto.sh "$QUARTO_VERSION"

# Install System Dependencies for R packages
setup_something install-os-deps.sh

# Install Apptainer
setup_something install-apptainer.sh $APPTAINER_VERSION

# Install NVIDIA Driver
setup_something install-nvidia.sh

# Cronjob to ensure login nodes are set up
#  and service restarts can be automated via state fles
(crontab -l ; echo "0-59/1 * * * * /opt/rstudio/scripts/rc.pwb")| crontab -

if [ -n "$FAILED" ]; then
  echo "WARNING: the following steps reported errors:$FAILED (logs in /opt/*-install.log)"
fi

