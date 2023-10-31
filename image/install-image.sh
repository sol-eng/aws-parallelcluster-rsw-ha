#!/bin/bash

R_VERSION_LIST="4.3.1"
R_VERSION_DEFAULT=4.3.1

PYTHON_VERSION_LIST="3.11.6"
PYTHON_VERSION_DEFAULT=3.11.6

QUARTO_VERSION=1.4.449

PWB_VERSION=2023.09.1-494.pro2

APPTAINER_VERSION="1.2.4"

PWB_CONFIG_DIR="/opt/rstudio/etc/rstudio"


function setup_something() {
# $1 - script to be run
# $2 - parameters
aws s3 cp s3://hpc-scripts1234/image/$1 /tmp
bash /tmp/$1 $2 $3
rm -f /tmp/$1
}

# Update all packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Disable apparmor
systemctl stop apparmor && systemctl disable apparmor

# Setup LDAP auth
#setup_something setup-sssd.sh
setup_something install-dummy.sh

# Install R version(s)
setup_something install-r.sh "$R_VERSION_LIST" $R_VERSION_DEFAULT

# Install Python version(s)
setup_something install-python.sh "$PYTHON_VERSION_LIST" $PYTHON_VERSION_DEFAULT

# Install Quarto
setup_something install-quarto.sh "$QUARTO_VERSION"

# Install System Dependencies for R packages
##setup_something install-os-deps.sh

# Install Workbench 
setup_something install-pwb.sh $PWB_VERSION 

# Install Apptainer
setup_something install-apptainer.sh $APPTAINER_VERSION

