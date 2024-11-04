for i in install*.sh *.R
do
aws s3 cp $i s3://hpc-scripts-ide-team-556a5ad/image/$i
done

pcluster build-image -c image-config.yaml -i $1

