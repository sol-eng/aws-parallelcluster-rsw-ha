# Install PWB session components 

# cf. https://docs.posit.co/rsw/integration/launcher-slurm/#8-install-rstudio-server-pro-session-components-on-slurm-compute-nodes

PWB_VER=$1

if [ $OS=="ubuntu" ]; then 
	curl -O https://s3.amazonaws.com/rstudio-ide-build/session/$OSVER/amd64/rsp-session-$OSVER-${PWB_VER}-amd64.tar.gz
else
	curl -O https://s3.amazonaws.com/rstudio-ide-build/session/$OSVER/x86_64/rsp-session-$OSVER-${PWB_VER}-x86_64.tar.gz
fi

mkdir -p /usr/lib/rstudio-server 
tar xvfz rsp-session-* tar -C /usr/lib/rstudio-server --strip-components=1
rm -f rsp-session-*

# install os dependencies 
if [ $OS=="ubuntu" ]; then 
	apt-get install -y curl libcurl4-gnutls-dev libssl-dev libuser1-dev libpq5 rrdtool
else
	if ( ! rpm -qi epel-release ); then 
		yum -y install epel-release 
		crb enable
	fi
	yum install -y libcurl-devel libpq libuser-devel openssl-devel rrdtool
fi

# /opt/R/4.3.2/bin/R -q -e 'install.packages("pak", repos = sprintf("https://r-lib.github.io/p/pak/stable/%s/%s/%s", .Platform$pkgType, R.Version()$os, R.Version()$arch))'
# x<-as.data.frame(available.packages()) 
# my<-pkg_sysreqs(x$Package)
# options(pkg.sysreqs_platform="centos-9")