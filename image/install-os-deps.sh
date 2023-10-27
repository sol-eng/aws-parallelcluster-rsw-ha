#!/bin/bash

apt-get update 

# CRAN system-deps
# (cf. "Install System Prerequisites" 
# at https://packagemanager.rstudio.com/client/#/repos/2/overview)

apt-get install -y automake bowtie2 bwidget cargo cmake coinor-libclp-dev dcraw gdal-bin git gsfonts haveged imagej imagemagick jags libapparmor-dev libarchive-dev libavfilter-dev libcairo2-dev libcurl4-openssl-dev libfftw3-dev libfontconfig1-dev libfreetype6-dev libfribidi-dev libgdal-dev libgeos-dev libgit2-dev libgl1-mesa-dev libglib2.0-dev libglpk-dev libglu1-mesa-dev libgmp3-dev libgpgme11-dev libgsl0-dev libharfbuzz-dev libhdf5-dev libhiredis-dev libicu-dev libimage-exiftool-perl libjpeg-dev libjq-dev libleptonica-dev libmagic-dev libmagick++-dev libmpfr-dev libmysqlclient-dev libnetcdf-dev libnode-dev libopencv-dev libopenmpi-dev libpng-dev libpoppler-cpp-dev libpq-dev libproj-dev libprotobuf-dev libquantlib0-dev librdf0-dev librsvg2-dev libsasl2-dev libsecret-1-dev libsndfile1-dev libsodium-dev libsqlite3-dev libssh2-1-dev libssl-dev libtesseract-dev libtiff-dev libudunits2-dev libwebp-dev libxft-dev libxml2-dev libxslt-dev libzmq3-dev make mongodb nvidia-cuda-dev ocl-icd-opencl-dev pandoc pandoc-citeproc pari-gp perl pkg-config protobuf-compiler python3 rustc saga tcl tesseract-ocr-eng texlive tk tk-dev tk-table unixodbc-dev zlib1g-dev

# Bioconductor system-deps 
# (cf. "Install System Prerequisites for the Repo’s Packages" 
#   at https://packagemanager.rstudio.com/client/#/repos/4/overview)
 
apt-get install -y bwidget git gsfonts imagemagick jags libcurl4-openssl-dev libglpk-dev libgsl0-dev libhiredis-dev libmagick++-dev libssl-dev libxml2-dev make ocl-icd-opencl-dev pandoc perl pkg-config python3 tk-table
