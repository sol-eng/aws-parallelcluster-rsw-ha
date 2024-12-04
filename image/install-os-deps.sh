#!/bin/bash

apt-get update 


# Google Chrome
[ $(which google-chrome) ] || apt-get install -y gnupg curl
[ $(which google-chrome) ] || curl -fsSL -o /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
[ $(which google-chrome) ] || DEBIAN_FRONTEND='noninteractive' apt-get install -y /tmp/google-chrome.deb
rm -f /tmp/google-chrome.deb

# CRAN system-deps
# (cf. "Install System Prerequisites" 
# at https://packagemanager.rstudio.com/client/#/repos/2/overview)
# extract deps there and then run | sort -u  | grep apt-get  | awk '{print $4}' | tr '\n' ' '

apt-get install -y automake bwidget cargo cmake coinor-libclp-dev coinor-libsymphony-dev coinor-symphony dcraw default-jdk gdal-bin git gsfonts haveged imagej imagemagick jags libapparmor-dev libarchive-dev libavfilter-dev libboost-all-dev libcairo2-dev libcurl4-openssl-dev libfftw3-dev libfluidsynth-dev libfontconfig1-dev libfreetype6-dev libfribidi-dev libgdal-dev libgeos-dev libgit2-dev libgl1-mesa-dev libglib2.0-dev libglpk-dev libglu1-mesa-dev libgmp3-dev libgpgme11-dev libgrpc++-dev libgsl0-dev libharfbuzz-dev libhdf5-dev libhiredis-dev libicu-dev libimage-exiftool-perl libjpeg-dev libjq-dev libleptonica-dev libmagic-dev libmagick++-dev libmpfr-dev libmysqlclient-dev libnetcdf-dev libnode-dev libopencv-dev libopenmpi-dev libpng-dev libpoppler-cpp-dev libpq-dev libproj-dev libprotobuf-dev libqgis-dev libquantlib0-dev librdf0-dev librsvg2-dev libsasl2-dev libsecret-1-dev libsndfile1-dev libsodium-dev libsqlite3-dev libssh-dev libssh2-1-dev libssl-dev libtesseract-dev libtiff-dev libudunits2-dev libwebp-dev libxml2-dev libxslt-dev libzmq3-dev make nvidia-cuda-dev ocl-icd-opencl-dev pandoc pari-gp perl pkg-config protobuf-compiler protobuf-compiler-grpc python3 rustc saga tcl tesseract-ocr-eng texlive tk tk-dev tk-table unixodbc-dev xz-utils zlib1g-dev

# Bioconductor system-deps 
# (cf. "Install System Prerequisites for the Repo’s Packages" 
#   at https://packagemanager.rstudio.com/client/#/repos/4/overview)
# extract deps there and then run | sort -u  | grep apt-get  | awk '{print $4}' | tr '\n'''
 
apt-get install -y bwidget default-jdk git gsfonts imagemagick jags libcurl4-openssl-dev libeigen3-dev libgsl0-dev libmagick++-dev libopenbabel-dev libssl-dev libxml2-dev make ocl-icd-opencl-dev pandoc perl pkg-config python3 tk-table