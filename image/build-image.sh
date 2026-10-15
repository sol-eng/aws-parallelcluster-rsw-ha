#!/bin/bash
#
# Build the custom ParallelCluster AMI with R, Python, Quarto, Apptainer etc.
#
# The S3 bucket, subnet and security group are taken from the Pulumi stack
# (run Pulumi first). Software versions are pinned in install-image.sh.
#
# Usage: ./build-image.sh <IMAGENAME> <PULUMI_STACK>

set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $(basename "$0") <IMAGENAME> <PULUMI_STACK>" >&2
    exit 1
}

[ $# -eq 2 ] || usage
image_name=$1
stack=$2

stack_output() {
    pulumi stack output -C ../pulumi -s "$stack" "$1"
}

bucketname=$(stack_output s3_bucket_id)
subnet=$(stack_output vpc_private_subnet)
securitygroup=$(stack_output ssh_security_group)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "Uploading install scripts to s3://$bucketname/image/"
for i in install*.sh *.R
do
    sed "s/BUCKETNAME/$bucketname/g" "$i" > "$tmpdir/$i"
    aws s3 cp --only-show-errors "$tmpdir/$i" "s3://$bucketname/image/$i"
done

# Official ParallelCluster Ubuntu 24.04 (noble) AMI for the installed pcluster version
pcluster_version=$(pcluster version | jq -r .version)
my_ami=$(pcluster list-official-images --os ubuntu2404 --architecture x86_64 \
    | jq -r --arg v "$pcluster_version" '[.images[] | select(.version == $v)] | first | .amiId // empty')
[ -n "$my_ami" ] || { echo "ERROR: no official ubuntu2404 AMI found for pcluster $pcluster_version" >&2; exit 1; }
echo "Parent image: $my_ami (pcluster $pcluster_version)"

sed -e "s/@@PARENT_AMI@@/$my_ami/" \
    -e "s/@@BUCKETNAME@@/$bucketname/" \
    -e "s/@@SUBNET@@/$subnet/" \
    -e "s/@@SECURITYGROUP@@/$securitygroup/" \
    image-config.yaml > "$tmpdir/image-config.yaml"

pcluster build-image -c "$tmpdir/image-config.yaml" -i "$image_name" --suppress-validators ALL

cat <<EOF

Image build started. Check progress with
  pcluster describe-image -i $image_name
Once imageBuildStatus is BUILD_COMPLETE, put the reported ec2AmiInfo.amiId
into the AMI= line of your parallelcluster/envs/<name>.env file:
  pcluster describe-image -i $image_name | jq -r .ec2AmiInfo.amiId
EOF
