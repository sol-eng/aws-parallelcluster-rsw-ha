for i in install*.sh *.R
do
aws s3 cp $i s3://hpc-scripts1234/image/$i
done

pcluster build-image -c image-config.yaml -i img-2024_04_1_748_pro2 

