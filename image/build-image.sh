#!/bin/bash

usage() {
echo "Usage: "
echo "  `basename $0` <IMAGENAME> [<BUCKETNAME>]"  
}

if [ -z $1 ]; then 
   echo "Image Name not provided !"
   usage
   exit 
fi

bucketname=$2
if [ -z $2 ]; then
   bucketname="hpc-scripts1234"

   if [ ! -f .bucket.default ]; then 
      echo "<BUCKETNAME> not specified, falling back to default [hpc-script1234]"
   else 
      bucketname=`cat .bucket.default`
   fi
fi

tmpdir=`mktemp -d`
 
for i in install*.sh *.R
do
sed "s/BUCKETNAME/$bucketname/" $i > $tmpdir/$i
aws s3 cp $tmpdir/$i s3://$bucketname/image/$i
done

# Get a compatible ubuntu 2024 (noble) AMI
my_ami=`pcluster list-official-images |  jq -r '.images[] | select(.os == "ubuntu2404" and .architecture == "x86_64") | .amiId'`

cat image-config.yaml | sed "s/AMI/$my_ami/g" | sed "s/BUCKETNAME/$bucketname/" > $tmpdir/image-config.yaml

pcluster build-image -c $tmpdir/image-config.yaml -i $1 --suppress-validators ALL

#rm -rf $tmpdir

