#!/bin/bash

CLUSTERNAME="ukhsa-benchmark"
S3_BUCKETNAME="hpc-scripts1234"
SECURITYGROUP_RSW="sg-0838ae772a776ab8e"
SUBNETID="subnet-03259a81db5aec449"
REGION="eu-west-1"
KEY="michael"
AMI="ami-096344118352bdfa7"
AMI="ami-0e29904af11890d19"
CERT="/Users/michael/projects/aws/certs/michael.pem"

rm -rf tmp
mkdir -p tmp
cp -Rf scripts/* tmp
cat scripts/aliases.sh | sed "s#CERT#${CERT}#" > tmp/aliases.sh
cat scripts/install-rsw.sh | sed "s/PWB_VER/$PWB_VER/" | sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" > tmp/install-rsw.sh


aws s3 cp tmp/ s3://${S3_BUCKETNAME} --recursive 

cat config/cluster-config-wb.tmpl | \
	sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
        sed "s#SECURITYGROUP_RSW#${SECURITYGROUP_RSW}#g" | \
        sed "s#SUBNETID#${SUBNETID}#g" | \
        sed "s#REGION#${REGION}#g" | \
        sed "s#AMI#${AMI}#g" | \
        sed "s#KEY#${KEY}#g"  \
	> config/cluster-config-wb.yaml
pcluster create-cluster --cluster-name="$CLUSTERNAME" --cluster-config=config/cluster-config-wb.yaml --rollback-on-failure false 
