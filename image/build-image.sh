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
 
sed "s/BUCKETNAME/$bucketname/" image-config.yaml > $tmpdir/image-config.yaml


for i in install*.sh *.R
do
sed "s/BUCKETNAME/$bucketname/" $i > $tmpdir/$i
aws s3 cp $tmpdir/$i s3://$bucketname/image/$i
done

sed "s/BUCKETNAME/$bucketname/" image-config.yaml > $tmpdir/image-config.yaml

rm -rf $tmpdir

pcluster build-image -c image-config.yaml -i $1 --suppress-validators ALL
