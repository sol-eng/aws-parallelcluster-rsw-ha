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
   if [ ! -f .bucket.default ]; then 
      echo "<BUCKETNAME> not specified but no default in .bucket.default configured either !"
      usage
      exit
   fi
   bucketname=`cat .bucket.default` 
   echo "S3 Bucket Name not provided, attempting to use $bucketname as default"

   bucketname="hpc-scripts1234"
fi

tmpdir=`mktemp -d`
 
sed "s/BUCKETNAME/$bucketname/" image-config.yaml > $tmpdir/image-config.yaml


for i in install*.sh *.R
do
sed "s/BUCKETNAME/$bucketname/" $i > $tmpdir/$i
aws s3 cp $tmpdir/$i s3://$bucketname/image/$i
done

sed "s/BUCKETNAME/$bucketname/" image-config.yaml > tmp/image-config.yaml

rm -rf $tmpdir

pcluster build-image -c image-config.yaml -i $1 --suppress-validators ALL
