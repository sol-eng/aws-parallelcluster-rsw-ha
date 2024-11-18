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

for i in install*.sh *.R
do
aws s3 cp $i s3://$bucketname/image/$i
done

sed "s/BUCKETNAME/$bucketname/" image-config.tmpl > image-config.yaml

pcluster build-image -c image-config.yaml -i $1 --suppress-validators ALL
