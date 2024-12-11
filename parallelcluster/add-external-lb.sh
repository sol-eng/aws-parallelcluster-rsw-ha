#!/bin/bash
export cluster="security3"
tempfile=`mktemp`
aws elbv2 describe-tags --resource-arns $(aws elbv2 describe-target-groups --query 'TargetGroups[*].TargetGroupArn' --output text) --query "TagDescriptions[?Tags[?Key==\`parallelcluster:cluster-name\` && Value==\`$cluster\`]].ResourceArn" --output text > $tempfile
target_group_arn=`cat $tempfile`

# Query VPC ID
vpc_id=`aws elbv2 describe-target-groups --target-group-arns $target_group_arn  --query 'TargetGroups[0].VpcId' --output text`

# Add new SG
aws ec2 create-security-group --group-name my-security-group-$cluster --description "Security group for port 8787 access from everywhere" --vpc-id $vpc_id

my_sg_id=`aws ec2 describe-security-groups --filters Name=group-name,Values=my-security-group-$cluster --query 'SecurityGroups[0].GroupId' --output text`

aws ec2 authorize-security-group-ingress --group-id $my_sg_id --protocol tcp --port 8787 --cidr 0.0.0.0/0

# Find internet gw 
my_ig_id=`aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$vpc_id --query 'InternetGateways[*].InternetGatewayId' --output text`

my_rt_ids=`aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc_id --query "RouteTables[?Routes[?GatewayId=='$my_ig_id']].RouteTableId" --output text | sed 's/\t/,/'`

# List all subnets in vpc
my_public_subnet_ids=`aws ec2 describe-route-tables --filters Name=route-table-id,Values=$my_rt_ids --query 'RouteTables[*].Associations[?SubnetId!=null].SubnetId' --output text | tr -u "\n" " " `

# Create new LB in public subnet 
aws elbv2 create-load-balancer --name my-load-balancer-$cluster --subnets `echo $my_public_subnet_ids` --security-groups $my_sg_id --scheme internet-facing --type network 

my_lb_arn=`aws elbv2 describe-load-balancers --names my-load-balancer-$cluster --query 'LoadBalancers[0].LoadBalancerArn' --output text`

# Create Listener that forwards traffix to target group in private subnet 
aws elbv2 create-listener --load-balancer-arn $my_lb_arn --protocol TCP --port 8787 --default-actions Type=forward,TargetGroupArn=$target_group_arn
rm -f $tempfile
