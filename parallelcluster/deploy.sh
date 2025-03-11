#!/bin/bash

CLUSTERNAME="vpc"
STACKNAME="vpc"
PWB_VERSION="2024.12.1-563.pro5"
AMI="ami-09d641c6d0df34503"
#AMI="ami-0a23aa1812f0b93c8"
REGION="eu-west-1"
SINGULARITY_SUPPORT=false
BENCHMARK_SUPPORT=false
EASYBUILD_SUPPORT=false
CONFIG="default"
HPC_DOMAIN=mayer.cx
HPC_HOST="lance-launcher"
SSL=true
LOCAL=true

echo "Extracting values from pulumi setup"
KEY=`cd ../pulumi && pulumi stack output "key_pair id"  -s $STACKNAME`
DOMAINPWSecret=` cd ../pulumi && pulumi stack output "ad_password_arn" -s $STACKNAME `
EMAIL=`cd ../pulumi && pulumi config get email -s $STACKNAME`
AD_DNS=`cd ../pulumi && pulumi stack output ad_dns_1 -s $STACKNAME`
RSW_DB_HOST=`cd ../pulumi && pulumi stack output rsw_db_address -s $STACKNAME`
RSW_DB_USER=`cd ../pulumi && pulumi stack output rsw_db_user -s $STACKNAME`
RSW_DB_PASS=`cd ../pulumi && pulumi stack output rsw_db_pass -s $STACKNAME --show-secrets`
if ($SSL); then 
  SECURITYGROUP_RSW=`cd ../pulumi && pulumi stack output rsw_security_group_https -s $STACKNAME`
else
  SECURITYGROUP_RSW=`cd ../pulumi && pulumi stack output rsw_security_group_nohttps -s $STACKNAME`
fi
SLURM_DB_HOST=`cd ../pulumi && pulumi stack output slurm_db_endpoint -s $STACKNAME`
SLURM_DB_NAME=`cd ../pulumi && pulumi stack output slurm_db_name -s $STACKNAME`
SLURM_DB_USER=`cd ../pulumi && pulumi stack output slurm_db_user -s $STACKNAME`
SLURM_DB_PASS_ARN=`cd ../pulumi && pulumi stack output slurm_db_pass_arn -s $STACKNAME`
SECURE_COOKIE_KEY=`cd ../pulumi && pulumi stack output secure_cookie_key -s $STACKNAME --show-secrets`
BILLING_CODE=`cd ../pulumi && pulumi stack output billing_code -s $STACKNAME`
ELB_ACCESS=`cd ../pulumi && pulumi stack output iam_elb_access -s $STACKNAME`
S3_ACCESS=`cd ../pulumi && pulumi stack output iam_s3_access -s $STACKNAME`
S3_BUCKETNAME=`cd ../pulumi && pulumi stack output s3_bucket_id -s $STACKNAME`
SUBNETID=`cd ../pulumi && pulumi stack output vpc_private_subnet -s $STACKNAME`
SECURITYGROUP_SSH=`cd ../pulumi && pulumi stack output ssh_security_group -s $STACKNAME`


if ($SSL); then
    if [ -f certs/$HPC_DOMAIN.crt ] && [ -f certs/$HPC_DOMAIN.key ]; then 
        echo "$HPC_DOMAIN.crt and $HPC_DOMAIN.key found"
    else
        echo "Generating self-signed SSL certificate"  
        if [ ! -f certs/openssl.$HPC_DOMAIN.conf ]; then 
cat << EOF > certs/openssl.$HPC_DOMAIN.conf
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = CH 
ST = Basel Landschaft 
L = Allschwil
O = Posit
OU = Solution Engineering
CN = *.$HPC_DOMAIN
EOF
        fi
        openssl genpkey -algorithm RSA -out certs/$HPC_DOMAIN.key
        openssl req -x509 -nodes -days 365 -key certs/$HPC_DOMAIN.key -out certs/$HPC_DOMAIN.crt -config certs/openssl.$HPC_DOMAIN.conf
    fi
fi
echo "preparing scripts" 
rm -rf tmp
mkdir -p tmp
cp -Rf scripts/* tmp
if ($SSL); then cp -Rf certs/$HPC_DOMAIN.{key,crt} tmp; fi

cat scripts/install-pwb-config.sh | \
        sed "s#AD_DNS#${AD_DNS}#g" | \
        sed "s#RSW_DB_HOST#${RSW_DB_HOST}#g" | \
        sed "s#RSW_DB_USER#${RSW_DB_USER}#g" | \
       	sed "s#RSW_DB_PASS#${RSW_DB_PASS}#g" | \
        sed "s#SECURE_COOKIE_KEY#${SECURE_COOKIE_KEY}#g" | \
        sed "s#SINGULARITY_SUPPORT#${SINGULARITY_SUPPORT}#g" | \
	sed "s#BENCHMARK_SUPPORT#${BENCHMARK_SUPPORT}#g" | \
        sed "s#EASYBUILD_SUPPORT#${EASYBUILD_SUPPORT}#g" | \
        sed "s#LOCAL#${LOCAL}#g" | \
        sed "s#SSL#${SSL}#g" | \
        sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
	sed "s#CLUSTER_CONFIG#${CONFIG}#g" \
	> tmp/install-pwb-config.sh 

cat scripts/config-login.sh | \
        sed "s#AD_DNS#${AD_DNS}#g" | \
        sed "s#BENCHMARK_SUPPORT#${BENCHMARK_SUPPORT}#g" | \
        sed "s#HPC_DOMAIN#${HPC_DOMAIN}#g" | \
        sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
        sed "s#EASYBUILD_SUPPORT#${EASYBUILD_SUPPORT}#g" \
        > tmp/config-login.sh 

cat scripts/config-compute.sh | \
        sed "s#AD_DNS#${AD_DNS}#g" | \
	sed "s#BENCHMARK_SUPPORT#${BENCHMARK_SUPPORT}#g" | \
        sed "s#EASYBUILD_SUPPORT#${EASYBUILD_SUPPORT}#g"\
	> tmp/config-compute.sh 

cat config/cluster-config-wb.${CONFIG}.tmpl | \
        sed "s#PWB_VERSION#${PWB_VERSION}#g" | \
	sed "s#S3_BUCKETNAME#${S3_BUCKETNAME}#g" | \
        sed "s#HPC_DOMAIN#${HPC_DOMAIN}#g" | \
        sed "s#HPC_HOST#${HPC_HOST}#g" | \
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
        sed "s#ELB_ACCESS#${ELB_ACCESS}#g" | \
	sed "s#S3_ACCESS#${S3_ACCESS}#g" \
	> tmp/cluster-config-wb.yaml

aws s3 cp tmp/ s3://${S3_BUCKETNAME} --recursive 


#echo "Starting deployment"
pcluster create-cluster --suppress-validators ALL --cluster-name="$CLUSTERNAME" --cluster-config=tmp/cluster-config-wb.yaml --rollback-on-failure false 
