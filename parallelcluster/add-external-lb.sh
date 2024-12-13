#!/bin/bash
export cluster="security"

# Find existing internal LB ARN
tempfile=$(mktemp)
aws elbv2 describe-tags --resource-arns $(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerArn' --output text) \
--query "TagDescriptions[?Tags[?Key=='parallelcluster:cluster-name' && Value=='$cluster']].ResourceArn" --output text > $tempfile
internal_lb_arn=$(cat $tempfile)
rm $tempfile

# DNS Name of internal LB 
internal_lb_dns=`aws elbv2 describe-load-balancers --load-balancer-arns $internal_lb_arn --query 'LoadBalancers[0].DNSName' --output text`

# We need the head node id to inquire the IP address of the internal LB (the AWS API does not seem to expose the IP of a NLB)
head_node_id=`pcluster describe-cluster --cluster-name="$cluster" | jq -r .headNode.instanceId`

command="host $internal_lb_dns | awk '{print \$4}'"

command_id=`aws ssm send-command --instance-ids "$head_node_id" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["'"$command"'"]' | jq -r .Command.CommandId`

# IP address of internal NLB
internal_lb_ip=`aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$head_node_id" | jq -r .StandardOutputContent`

# Query VPC ID
vpc_id=`aws elbv2 describe-load-balancers --load-balancer-arns $internal_lb_arn --query 'LoadBalancers[0].VpcId' --output text`

# Create new Target group 
aws elbv2 create-target-group --name private-nlb-tgt-group-$cluster --protocol TCP --port 8787 --vpc-id $vpc_id --target-type ip

# Register target (use the ip of the internal  NLB)
aws elbv2 register-targets --target-group-arn $(aws elbv2 describe-target-groups --names private-nlb-tgt-group-$cluster --query 'TargetGroups[0].TargetGroupArn' --output text) --targets Id=$internal_lb_ip

# Add new SG
aws ec2 create-security-group --group-name my-security-group-$cluster --description "Security group for port 80/8787 access from everywhere" --vpc-id $vpc_id

my_sg_id=`aws ec2 describe-security-groups --filters Name=group-name,Values=my-security-group-$cluster --query 'SecurityGroups[0].GroupId' --output text`

aws ec2 authorize-security-group-ingress --group-id $my_sg_id --protocol tcp --port 80 --cidr 0.0.0.0/0

# Find internet gw 
my_ig_id=`aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$vpc_id --query 'InternetGateways[*].InternetGatewayId' --output text`

my_rt_ids=`aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc_id --query "RouteTables[?Routes[?GatewayId=='$my_ig_id']].RouteTableId" --output text | sed 's/\t/,/'`

# List all subnets in vpc
my_public_subnet_ids=`aws ec2 describe-route-tables --filters Name=route-table-id,Values=$my_rt_ids --query 'RouteTables[*].Associations[?SubnetId!=null].SubnetId' --output text | tr -u "\n" " " `

# Create new LB in public subnet 
aws elbv2 create-load-balancer --name my-load-balancer-$cluster --subnets `echo $my_public_subnet_ids` --security-groups $my_sg_id --scheme internet-facing --type network 

my_lb_arn=`aws elbv2 describe-load-balancers --names my-load-balancer-$cluster --query 'LoadBalancers[0].LoadBalancerArn' --output text`
target_group_arn=`aws elbv2 describe-target-groups --names private-nlb-tgt-group-$cluster --query 'TargetGroups[0].TargetGroupArn' --output text`

# Create Listener that forwards traffix to target group in private subnet 
aws elbv2 create-listener --load-balancer-arn $my_lb_arn --protocol TCP --port 80 --default-actions Type=forward,TargetGroupArn=$target_group_arn



