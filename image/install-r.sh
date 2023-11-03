#!/bin/bash

# cf. https://docs.posit.co/resources/install-r/

set -x 

exec > /opt/r-install.log
exec 2>&1

R_VERSION_LIST=${@: 2:$#}
R_VERSION_DEFAULT=${@: 1:1}


echo "R_VERSION_LIST": $R_VERSION_LIST
echo "R_VERSION_DEFAULT": $R_VERSION_DEFAULT

# Remove OS provided R 
apt remove -y r-base r-base-core r-base-dev r-base-html r-doc-html

if ( ! dpkg -l curl >& /dev/null); then 
apt-get update 
apt-get install -y curl
fi

if ( ! dpkg -l gdebi-core >& /dev/null); then 
apt-get update 
apt-get install -y gdebi-core
fi

if ( ! dpkg -l openjdk-11-jdk >& /dev/null); then
apt-get update
apt-get install -y openjdk-11-jdk
fi

for R_VERSION in $R_VERSION_LIST
do
  curl -O https://cdn.rstudio.com/r/ubuntu-2004/pkgs/r-${R_VERSION}_1_amd64.deb
  gdebi -n r-${R_VERSION}_1_amd64.deb
  rm -f r-${R_VERSION}_1_amd64.deb
done

# Configure R versions to have 
#  - appropriate snapshot 
#  - setup Java integration for rJava package
#  - setting user agent HTTP headers for getting binary packages
#  - preinstalling packages needed for the RStudio IDE integration
# Note: Install will run in parallel to speed up things

aws s3 cp s3://hpc-scripts1234/image/run.R /tmp

PATH_NOW=$PATH

for R_VERSION in $R_VERSION_LIST
do
  export PATH=/opt/R/${R_VERSION}/bin:$PATH
  /opt/R/${R_VERSION}/bin/Rscript /tmp/run.R && \
	JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64/ \
	  /opt/R/${R_VERSION}/bin/R CMD javareconf 
done

# Defining system default version
if [ ! -z $R_VERSION_DEFAULT ]; then
  ln -s /opt/R/$R_VERSION_DEFAULT/bin/R /usr/local/bin
  ln -s /opt/R/$R_VERSION_DEFAULT/bin/Rscript /usr/local/bin
fi


