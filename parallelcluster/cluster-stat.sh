#!/bin/bash

export clustername=$1

echo "Information for cluster $clustername"
echo "------------------------------------------"
echo ""
loginnode=$(aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" "Name=tag:parallelcluster:node-type,Values='LoginNode'" --query 'Reservations[*].Instances[?State.Name==`running`]' | jq -r '.[] | .[] | .InstanceId' | head -1 )

cmdid=$(aws ssm send-command  --instance-ids $loginnode --document-name "AWS-RunShellScript" --parameters commands="rstudio-server version" --query "Command.CommandId" --output text )
echo "Posit Workbench Version: `aws ssm list-command-invocations --command-id $cmdid --query 'CommandInvocations[].CommandPlugins[].{Status:Status,Output:Output}' --details | jq -r '.[] | .Output'`"
echo ""
echo "ELB URL: http://`pcluster describe-cluster --cluster-name=$clustername | jq -r '.loginNodes | .address' `:8787"
echo ""
echo "Posit User Password: `export cwd=$CWD && cd ../pulumi && pulumi stack output user_pass -s $clustername --show-secrets && cd $cwd `"
echo ""
echo "#InstanceID, PrivateDnsName, PublicDnsName, Role"
aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" --query 'Reservations[*].Instances[?State.Name==`running`]' | jq -r '.[] | .[] | [.InstanceId,.PrivateDnsName,.PublicDnsName,(.Tags | .[] | (select(.Key=="parallelcluster:node-type")) | .Value)] | @csv'

