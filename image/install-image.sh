#!/bin/bash

R_VERSION_LIST="4.3.2 4.2.3 4.1.3 4.0.5"
R_VERSION_DEFAULT=4.3.2

PYTHON_VERSION_LIST="3.11.6 3.10.13 3.9.18"
PYTHON_VERSION_DEFAULT=3.11.6

QUARTO_VERSION=1.4.449

PWB_VERSION=2023.09.1-494.pro2
#PWB_VERSION=2023.12.0-daily-322.pro4

APPTAINER_VERSION="1.2.5"


function setup_something() {
# $1 - script to be run
# $2 - parameters
aws s3 cp s3://hpc-scripts1234/image/$1 /tmp
bash /tmp/$1 ${@: 2:$#-1}
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
setup_something install-r.sh $R_VERSION_DEFAULT "$R_VERSION_LIST" 

# Install Python version(s)
setup_something install-python.sh $PYTHON_VERSION_DEFAULT "$PYTHON_VERSION_LIST"

# Install Quarto
setup_something install-quarto.sh "$QUARTO_VERSION"

# Install System Dependencies for R packages
##setup_something install-os-deps.sh

# Install Workbench 
setup_something install-pwb.sh $PWB_VERSION 

# Install Apptainer
setup_something install-apptainer.sh $APPTAINER_VERSION

