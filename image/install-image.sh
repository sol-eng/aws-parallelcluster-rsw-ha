#!/bin/bash

R_VERSION_LIST="4.4.0 4.3.3 4.2.3 4.1.3 4.0.5"
R_VERSION_DEFAULT=4.4.0

PYTHON_VERSION_LIST="3.11.9 3.10.14 3.9.19"
PYTHON_VERSION_DEFAULT=3.11.9

QUARTO_VERSION=1.4.455

PWB_VERSION=2024.04.1-748.pro2

APPTAINER_VERSION="1.3.1"


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

