# Install PWB session components 

# cf. https://docs.posit.co/rsw/integration/launcher-slurm/#8-install-rstudio-server-pro-session-components-on-slurm-compute-nodes

PWB_VER=$1

curl -O https://s3.amazonaws.com/rstudio-ide-build/server/bionic/amd64/rstudio-workbench-${PWB_VER}-amd64.deb
dpkg-deb -x rstudio-workbench-${PWB_VER}-amd64.deb /
rm -f rstudio-workbench-${PWB_VER}-amd64.deb

apt-get update 
apt-get install -y curl libcurl4-gnutls-dev \
			libssl1.0.0 libssl-dev \
			libuser libuser1-dev \
			rrdtool \
			libpq5 
