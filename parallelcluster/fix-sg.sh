cluster="security3"
my_ip=`curl ifconfig.me`

tmpfile=`mktemp`
aws ec2 describe-security-groups --query 'SecurityGroups[?IpPermissions[?IpRanges[?CidrIp==`0.0.0.0/0`] && FromPort==`22` && ToPort==`22`] && Tags[?Key==`parallelcluster:cluster-name`] && value=="$cluster"].[GroupId,GroupName]' --output text > $tmpfile 
while IFS= read -r sgtext
do
sg=`echo $sgtext | awk '{print $1}'`
sgname=`echo $sgtext | awk '{print $2}'`
echo ""
echo "Found security group $sg ($sgname) with public ssh access" 
echo "Limiting ssh access to IP address $my_ip"
#aws ec2 revoke-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr "0.0.0.0/0"
#aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22 --cidr "$my_ip/32"
if [[ $sgname == *"LoginNode"* ]]; then
    echo "This looks like a Login node, lets's also add an ingress for ports 8787 and 443"
#   aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 8787 --cidr "0.0.0.0/0"
#   aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 443 --cidr "0.0.0.0/0"
fi
done < ${tmpfile}
rm -f $tmpfile 
