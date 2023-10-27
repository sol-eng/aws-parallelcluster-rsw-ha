#!/bin/bash

# cf. https://docs.posit.co/resources/install-r/

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

for R_VERSION in $1
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

aws s3 cp s3://hpc-scripts1234/image/package.R /tmp
aws s3 cp s3://hpc-scripts1234/image/configure.R /tmp

for R_VERSION in $1
do
  #/opt/R/${R_VERSION}/bin/Rscript /tmp/configure.R && \
	#/opt/R/${R_VERSION}/bin/Rscript /tmp/package.R && \
	JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64/ \
	  /opt/R/${R_VERSION}/bin/R CMD javareconf & 
done
wait

# Defining system default version
if [ ! -z $2 ]; then
  ln -s /opt/R/$2/bin/R /usr/local/bin
  ln -s /opt/R/$2/bin/Rscript /usr/local/bin
fi


