#!/bin/bash

R_VERSION_LIST="4.5.2 4.4.3 4.3.3 4.2.3 4.1.3 4.0.5"
R_VERSION_DEFAULT=4.5.2

PYTHON_VERSION_LIST="3.13.5 3.12.10 3.11.13 3.10.18"
PYTHON_VERSION_DEFAULT=3.13.5

QUARTO_VERSION=1.7.32

APPTAINER_VERSION="1.4.1"

QUARTO_VERSION=1.4.555

PWB_VERSION=2025.08.0-daily-283.pro2

function setup_something() {
# $1 - script to be run
# $2 - parameters
aws s3 cp s3://BUCKETNAME/image/$1 /tmp
bash /tmp/$1 ${@: 2:$#-1}
rm -f /tmp/$1
}

# Update all packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Disable apparmor
# systemctl stop apparmor && systemctl disable apparmor

# Setup LDAP auth
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

# Cronjob to ensure login nodes are set up 
#  and service restarts can be automated via state fles
(crontab -l ; echo "0-59/1 * * * * /opt/rstudio/scripts/rc.pwb")| crontab -

