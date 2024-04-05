#!/bin/bash
source globals.sh

for i in install*.sh *.R
do
aws s3 cp $i $S3_URL/$i
done

sed "s/XXXAMIXXX/$AMI/" image-config.yaml > image-config-${OSVER}.yaml

pcluster build-image -c image-config-${OSVER}.yaml -i workbench-${PWB_VERSION//\./-}-$OS-$OSNUM  

