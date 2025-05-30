# Needs to be run as an admin that has write permissions to /etc/rstudio
# 
# This script when run against any R version will 
# * figure out which compatible BioConductor Version exist
# * get all the URLs for the repositories of BioConductor
# * Add both CRAN and BioConductor 
#       into files in /etc/rstudio/repos/repos-x.y.z.conf
# * add entries into /etc/rstudio/r-versions to define the respective 
#       R version (x.y.z) and point to the repos.conf file  
# * update Rprofile.site with the same repository informations 
# * add renv config into Renviron.site to use 
#       a global cache in $renvdir  
# * install all needed R packages for Workbench to work and add them 
#       in a separate .libPath() ($basepackagedir/x.y.z)
# * create a pak pkg.lock file in $basepackagedir/x.y.z
#       for increased reproducibility
# * auto-detect which OS it is running on and add binary package support
# * uses a packagemanager running at $pmurl 
#       with repositories bioconductor and cran configured and named as such
# * assumes R binaries are installed into /opt/R/x.y.z

# main config parameters

# root folder for global renv cache 
renvdir<-"/home/renv"

# packagemanager URL to be used
pmurl <- "https://packagemanager.posit.co"

# place to create rstudio integration for package repos
rsconfigdir <- "/opt/rstudio/etc/rstudio" 

binaryflag<-""

if(file.exists("/etc/debian_version")) {
    binaryflag <- paste0("__linux__/",system(". /etc/os-release && echo $VERSION_CODENAME", intern = TRUE),"/")
}

if(file.exists("/etc/redhat-release")) {
    binaryflag <- paste0("__linux__/centos",system(". /etc/os-release && echo $VERSION_ID", intern = TRUE),"/")
}

currver <- paste0(R.Version()$major,".",R.Version()$minor)

libdir <- paste0(R.home(),"/site-library")

if(dir.exists(libdir)) {unlink(libdir,recursive=TRUE)}
dir.create(libdir,recursive=TRUE)
.libPaths(libdir)

if(dir.exists("/tmp/curl")) {unlink("/tmp/curl",recursive=TRUE)}
dir.create("/tmp/curl")
install.packages(c("rjson","RCurl","pak","BiocManager","remotes"),"/tmp/curl", repos=paste0(pmurl,"/cran/",binaryflag,"latest"))
library(RCurl,lib.loc="/tmp/curl")
library(rjson,lib.loc="/tmp/curl")
library(remotes,lib.loc="/tmp/curl")

jsondata<-fromJSON(file="https://raw.githubusercontent.com/rstudio/rstudio/main/src/cpp/session/resources/dependencies/r-packages.json")
pnames<-c()
for (feature in jsondata$features) { pnames<-unique(c(pnames,feature$packages)) }

currver <- paste0(R.Version()$major,".",R.Version()$minor)
paste("version",currver)

#Start with a starting date for the time-based snapshot 60 days past the R release
releasedate <- as.Date(paste0(R.version$year,"-",R.version$month,"-",R.version$day))
paste("release", releasedate)
 
#Attempt to install packages from snapshot - if snapshot does not exist, decrease day by 1 and try again
getreleasedate <- function(repodate){
  
  repo=paste0(pmurl,"/cran/",binaryflag,repodate)
  paste(repo)
  URLfound=FALSE
  while(!URLfound) {
   if (!RCurl::url.exists(paste0(repo,"/src/contrib/PACKAGES"),useragent="curl/7.39.0 Rcurl/1.95.4.5")) {
	repodate<-as.Date(repodate)-1
        repo=paste0(pmurl,"/cran/",binaryflag,repodate)
   } else {
   URLfound=TRUE
   }
 }
 return(repodate)
}

releasedate <- getreleasedate(as.Date(releasedate)+60)
paste("snapshot selected", releasedate)

#Final CRAN snapsot URL
repo=paste0(pmurl,"/cran/",binaryflag,releasedate)
options(repos=c(CRAN=repo))

paste("CRAN Snapshot", repo)

avpack<-available.packages(paste0(repo,"/src/contrib"))

library(pak,lib.loc="/tmp/curl")
.libPaths("/tmp/curl")

#Install all packages and their dependencies needed for RSW
os_name=system(". /etc/os-release && echo $ID", intern = TRUE)
os_vers=system(". /etc/os-release && echo $VERSION_ID", intern = TRUE)

#Let's also pre-install tidyverse, clustermq, batchtools and microbenchmark
Sys.setenv("CLUSTERMQ_USE_SYSTEM_LIBZMQ" = 0)
pnames=c(pnames,"pak","tidyverse","clustermq","batchtools","microbenchmark")

packages_needed<-pnames[pnames %in% avpack]

# paste("Installing system dependencies")
# sysdeps<-pak::pkg_sysreqs(packages_needed)
# system(sysdeps$pre_install)
# system(sysdeps$install_scripts)
# system(sysdeps$post_install)

paste("Installing packages for RSW integration")
pak::pkg_install(packages_needed,lib=libdir)
paste("Creating lock file for further reproducibility")
pak::lockfile_create(packages_needed,lockfile=paste0(libdir,"/pkg.lock"))

## workaround for clustermq as it cannot cooperate with pak... 
#if ( paste0(R.Version()$major,".",R.Version()$minor)>"4.3.0" ) { 
#  install_github("mschubert/clustermq@v0.9.1",lib=libdir)
#}

paste("Setting up global renv cache")
sink(paste0("/opt/R/",currver,"/lib/R/etc/Renviron.site"), append=TRUE)
  cat("RENV_PATHS_PREFIX_AUTO=TRUE\n")
  cat(paste0("RENV_PATHS_CACHE=", renvdir, "\n"))
  cat(paste0("RENV_PATHS_SANDBOX=", renvdir, "/sandbox\n"))
  cat("RENV_CONFIG_PAK_ENABLED=TRUE\n")
sink()

paste("Configuring Bioconductor")
# Prepare for Bioconductor
options(BioC_mirror = paste0(pmurl,"/bioconductor"))
options(BIOCONDUCTOR_CONFIG_FILE = paste0(pmurl,"/bioconductor/config.yaml"))
sink(paste0("/opt/R/",currver,"/lib/R/etc/Rprofile.site"),append=FALSE)
options(BioC_mirror = paste0(pmurl,"/bioconductor"))
options(BIOCONDUCTOR_CONFIG_FILE = paste0(pmurl,"/bioconductor/config.yaml"))
sink()

# Make sure BiocManager is loaded - needed to determine BioConductor Version
library(BiocManager,lib.loc="/tmp/curl",quietly=TRUE,verbose=FALSE)

# Version of BioConductor as given by BiocManager (can also be manually set)
biocvers <- BiocManager::version()

paste("Defining repos and setting them up in repos.conf as well as Rprofile.site")
# Bioconductor Repositories
r<-BiocManager::repositories(version=biocvers)

# enforce CRAN is set to our snapshot 
r["CRAN"]<-repo

# Make sure CRAN is listed as first repository (rsconnect deployments will start
# searching for packages in repos in the order they are listed in options()$repos
# until it finds the package
# With CRAN being the most frequenly use repo, having CRAN listed first saves 
# a lot of time
nr=length(r)
r<-c(r[nr],r[1:nr-1])

system(paste0("mkdir -p ",rsconfigdir,"/repos"))
filename=paste0(rsconfigdir,"/repos/repos-",currver,".conf")
sink(filename)
for (i in names(r)) {cat(noquote(paste0(i,"=",r[i],"\n"))) }
sink()

x<-unlist(strsplit(R.home(),"[/]"))
r_home<-paste0(x[2:length(x)-2],"/",collapse="")

sink(paste0(rsconfigdir,"/r-versions"), append=TRUE)
cat("\n")
cat(paste0("Path: ",r_home,"\n"))
cat(paste0("Label: R","\n"))
cat(paste0("Repo: ",filename,"\n"))
cat(paste0("Script: /opt/R/",currver,"/lib/R/etc/ldpaths \n"))
cat("\n")
sink()

sink(paste0("/opt/R/",currver,"/lib/R/etc/Rprofile.site"),append=FALSE)
if ( currver < "4.1.0" ) {
  cat('.env = new.env()\n')
}
cat('local({\n')
cat('r<-options()$repos\n')
for (line in names(r)) {
   cat(paste0('r["',line,'"]="',r[line],'"\n'))
}
cat('options(repos=r)\n') 

options(BioC_mirror = paste0(pmurl,"/bioconductor"))
options(BIOCONDUCTOR_CONFIG_FILE = paste0(pmurl,"/bioconductor/config.yaml"))

if ( currver < "4.1.0" ) {
cat('}, envir = .env)\n')
cat('attach(.env)\n')
} else {
cat('})\n')
}
sink()
