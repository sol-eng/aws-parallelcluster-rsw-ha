#!/bin/bash
export cluster="wb-2024-09-2"
export cluster_pulumi="wb-2024-09-2"
# Find existing internal LB ARN
internal_lb_arn=`for arn in $(aws elbv2 describe-load-balancers --query "LoadBalancers[*].LoadBalancerArn" --output text); do
    tags=$(aws elbv2 describe-tags --resource-arns $arn --query "TagDescriptions[].Tags[?Key=='parallelcluster:cluster-name' && Value=='$cluster']" --output text)
    if [ -n "$tags" ]; then
        echo "$arn"
    fi
done`

# Get the Load balancer name because the name will map to the ENI description
lb_name=`aws elbv2 describe-load-balancers --load-balancer-arns $internal_lb_arn --query 'LoadBalancers[0].LoadBalancerName' --output text`

internal_lb_ip=`aws ec2 describe-network-interfaces --filters "Name=interface-type,Values=network_load_balancer" "Name=description,Values=*$lb_name*" --query "NetworkInterfaces[*].[PrivateIpAddress]" --output text`

# Register target (use the ip of the internal  NLB)
aws elbv2 register-targets --target-group-arn $(aws elbv2 describe-target-groups --names public-nlb-tg-$cluster_pulumi --query 'TargetGroups[0].TargetGroupArn' --output text) --targets Id=$internal_lb_ip

