#!/bin/bash

CLUSTERNAME="benchmark"
SECURITYGROUP_RSW="sg-09ca531e5331195f1"
AMI="ami-0fbfbe3c206a631d2"
REGION="eu-west-1"
SINGULARITY_SUPPORT=false
BENCHMARK_SUPPORT=true
CONFIG="benchmark"

echo "Extracting values from pulumi setup"
SUBNETID=`cd ../pulumi && pulumi stack output vpc_subnet2  -s $CLUSTERNAME` 
KEY=`cd ../pulumi && pulumi stack output "key_pair id"  -s $CLUSTERNAME`
DOMAINPWSecret=` cd ../pulumi && pulumi stack output "domain_password_arn" -s $CLUSTERNAME `
CERT="${KEY}.pem"
EMAIL=`echo $KEY | cut -d "-" -f 1`
AD_DNS=`cd ../pulumi && pulumi stack output ad_dns_1 -s $CLUSTERNAME`
RSW_DB_HOST=`cd ../pulumi && pulumi stack output rsw_db_address -s $CLUSTERNAME`
RSW_DB_USER=`cd ../pulumi && pulumi stack output rsw_db_user -s $CLUSTERNAME`
RSW_DB_PASS=`cd ../pulumi && pulumi stack output rsw_db_pass -s $CLUSTERNAME`
SLURM_DB_HOST=`cd ../pulumi && pulumi stack output slurm_db_endpoint -s $CLUSTERNAME`
SLURM_DB_NAME=`cd ../pulumi && pulumi stack output slurm_db_name -s $CLUSTERNAME`
SLURM_DB_USER=`cd ../pulumi && pulumi stack output slurm_db_user -s $CLUSTERNAME`
SLURM_DB_PASS_ARN=`cd ../pulumi && pulumi stack output slurm_db_pass_arn -s $CLUSTERNAME`
SECURE_COOKIE_KEY=`cd ../pulumi && pulumi stack output secure_cookie_key -s $CLUSTERNAME`
BILLING_CODE=`cd ../pulumi && pulumi stack output billing_code -s $CLUSTERNAME`
ELB_ACCESS=`cd ../pulumi && pulumi stack output elb_access -s $CLUSTERNAME`
S3_BUCKETNAME=`cd ../pulumi && pulumi stack output s3_bucket_id -s $CLUSTERNAME`
SECURITYGROUP_SSH=`cd ../pulumi && pulumi stack output security_group_ssh -s $CLUSTERNAME`
echo "preparing scripts" 
rm -rf tmp
mkdir -p tmp
cp -Rf scripts/* tmp

cat scripts/install-pwb-config.sh | \
        sed "s#AD_DNS#${AD_DNS}#g" | \
        sed "s#RSW_DB_HOST#${RSW_DB_HOST}#g" | \
        sed "s#RSW_DB_USER#${RSW_DB_USER}#g" | \
       	sed "s#RSW_DB_PASS#${RSW_DB_PASS}#g" | \
        sed "s#SECURE_COOKIE_KEY#${SECURE_COOKIE_KEY}#g" | \
        sed "s#SINGULARITY_SUPPORT#${SINGULARITY_SUPPORT}#g" | \
	sed "s#BENCHMARK_SUPPORT#${BENCHMARK_SUPPORT}#g" | \
	sed "s#CLUSTER_CONFIG#${CONFIG}#g" \
	> tmp/install-pwb-config.sh 

cat scripts/config-compute.sh | \
	sed "s#BENCHMARK_SUPPORT#${BENCHMARK_SUPPORT}#g" \
	> tmp/config-compute.sh 

aws s3 cp tmp/ s3://${S3_BUCKETNAME} --recursive 

cat config/cluster-config-wb.${CONFIG}.tmpl | \
	sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
        sed "s#SECURITYGROUP_RSW#${SECURITYGROUP_RSW}#g" | \
        sed "s#SUBNETID#${SUBNETID}#g" | \
        sed "s#REGION#${REGION}#g" | \
        sed "s#AMI#${AMI}#g" | \
        sed "s#SLURM_DB_HOST#${SLURM_DB_HOST}#g" | \
        sed "s#SLURM_DB_NAME#${SLURM_DB_NAME}#g" | \
        sed "s#SLURM_DB_USER#${SLURM_DB_USER}#g" | \
       	sed "s#SLURM_DB_PASS_ARN#${SLURM_DB_PASS_ARN}#g" | \
	sed "s#DOMAINPWSecret#${DOMAINPWSecret}#g" | \
        sed "s#KEY#${KEY}#g" | \
	sed "s#EMAIL#${EMAIL}#g" | \
	sed "s#BILLING_CODE#${BILLING_CODE}#g" | \
        sed "s#SECURITYGROUP_SSH#${SECURITYGROUP_SSH}#g" | \
        sed "s#ELB_ACCESS#${ELB_ACCESS}#g" \
	> config/cluster-config-wb.yaml

aws s3 cp config/cluster-config-wb.yaml s3://${S3_BUCKETNAME}

echo "Starting deployment"
pcluster create-cluster --cluster-name="$CLUSTERNAME" --cluster-config=config/cluster-config-wb.yaml --rollback-on-failure false 
