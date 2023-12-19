#!/bin/bash

CLUSTERNAME="full"
S3_BUCKETNAME="hpc-scripts1234a"
SECURITYGROUP_RSW="sg-02f5bac286a0df0b8"
AMI="ami-087ccbe156d606047"
REGION="eu-west-1"
SINGULARITY_SUPPORT=false
CONFIG="benchmark"

echo "Extracting values from pulumi setup"
SUBNETID=`cd ../pulumi && pulumi stack output vpc_subnet` 
KEY=`cd ../pulumi && pulumi stack output "key_pair id" `
DOMAINPWSecret=` cd ../pulumi && pulumi stack output "domain_password_arn" `
CERT="${KEY}.pem"
EMAIL=`echo $KEY | cut -d "-" -f 1`
AD_DNS=`cd ../pulumi && pulumi stack output ad_dns_1`
DB_HOST=`cd ../pulumi && pulumi stack output db_address`
DB_USER=`cd ../pulumi && pulumi stack output db_user`
DB_PASS=`cd ../pulumi && pulumi stack output db_pass`
SECURE_COOKIE_KEY=`cd ../pulumi && pulumi stack output secure_cookie_key`
BILLING_CODE=`cd ../pulumi && pulumi stack output billing_code`


echo "preparing scripts" 
rm -rf tmp
mkdir -p tmp
cp -Rf scripts/* tmp

cat scripts/install-pwb-config.sh | \
        sed "s#AD_DNS#${AD_DNS}#g" | \
        sed "s#DB_HOST#${DB_HOST}#g" | \
        sed "s#DB_USER#${DB_USER}#g" | \
       	sed "s#DB_PASS#${DB_PASS}#g" | \
        sed "s#SECURE_COOKIE_KEY#${SECURE_COOKIE_KEY}#g" | \
        sed "s#SINGULARITY_SUPPORT#${SINGULARITY_SUPPORT}#g" | \
	sed "s#CLUSTER_CONFIG#${CONFIG}#g" \
	> tmp/install-pwb-config.sh 

aws s3 cp tmp/ s3://${S3_BUCKETNAME} --recursive 

cat config/cluster-config-wb.${CONFIG}.tmpl | \
	sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
        sed "s#SECURITYGROUP_RSW#${SECURITYGROUP_RSW}#g" | \
        sed "s#SUBNETID#${SUBNETID}#g" | \
        sed "s#REGION#${REGION}#g" | \
        sed "s#AMI#${AMI}#g" | \
	sed "s#DOMAINPWSecret#${DOMAINPWSecret}#g" | \
        sed "s#KEY#${KEY}#g" | \
	sed "s#EMAIL#${EMAIL}#g" | \
	sed "s#BILLING_CODE#${BILLING_CODE}#g" \
	> config/cluster-config-wb.yaml

echo "Starting deployment"
pcluster create-cluster --cluster-name="$CLUSTERNAME" --cluster-config=config/cluster-config-wb.yaml --rollback-on-failure false 
