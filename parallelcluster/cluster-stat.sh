#!/bin/bash

export clustername=$1

echo "Information for cluster $clustername"
echo "------------------------------------------"
echo ""
headnode=$(aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" "Name=tag:parallelcluster:node-type,Values='HeadNode'" | jq -r '.Reservations |  .[] | .Instances | .[] | .InstanceId')

cmdid=$(aws ssm send-command  --instance-ids $headnode --document-name "AWS-RunShellScript" --parameters commands="rstudio-server version" --query "Command.CommandId" --output text )
echo "Posit Workbench Version: `aws ssm list-command-invocations --command-id $cmdid --query 'CommandInvocations[].CommandPlugins[].{Status:Status,Output:Output}' --details | jq -r '.[] | .Output'`"
echo ""
echo "ELB URL: http://`pcluster describe-cluster --cluster-name=$clustername | jq -r '.loginNodes | .address' `:8787"
echo ""
echo "Posit User Password: `export cwd=$CWD && cd ../pulumi && pulumi stack select $clustername && pulumi stack output user_password && cd $cwd `"
echo ""
echo "#InstanceID, PrivateDnsName, PublicDnsName, Role"
aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" | \
    jq -r '.Reservations |  .[] | .Instances | .[] | [.InstanceId,.PrivateDnsName,.PublicDnsName,(.Tags | .[] | (select(.Key=="parallelcluster:node-type")) | .Value) ] | @csv'
