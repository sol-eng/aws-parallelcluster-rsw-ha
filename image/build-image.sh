#!/bin/bash
source globals.sh

S3_URL="s3://hpc-scripts1234/image/$OS-$OSNUM"

mkdir -p tmp
cp install*.sh globals.sh *.R tmp
sed "s#S3_URL#${S3_URL}#" install-image.sh > tmp/install-image.sh

pushd tmp
for i in install*.sh globals.sh *.R
do
aws s3 cp $i $S3_URL/$i
done

popd

sed "s/XXXAMIXXX/$AMI/" image-config.yaml | \
    sed "s#S3_URL#${S3_URL}#" > tmp/image-config.yaml 

pcluster build-image -c tmp/image-config.yaml -i workbench-${PWB_VERSION//\./-}-$OS-$OSNUM  

#rm -rf tmp 
