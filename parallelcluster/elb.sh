aws elbv2 create-target-group --name ukhsa-pwb --protocol TCP --port 8787 --target-type instance --vpc-id  vpc-1486376d
aws elbv2 register-targets --target-group-arn arn:aws:elasticloadbalancing:eu-west-1:637485797898:targetgroup/ukhsa-pwb/07f85264ff0fdb04 --targets Id=i-0312663369d9caec2 Id=i-09c3bf12e0d4bac24

aws elbv2 create-load-balancer --name ukhsa-elb --type network --subnets subnet-03259a81db5aec449 subnet-9bbd91c1

aws elbv2 create-listener \
    --load-balancer-arn arn:aws:elasticloadbalancing:eu-west-1:637485797898:loadbalancer/net/ukhsa-elb/eb83764ca63038ed \
    --protocol TCP \
    --port 8787 \
    --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:eu-west-1:637485797898:targetgroup/ukhsa-pwb/07f85264ff0fdb04
