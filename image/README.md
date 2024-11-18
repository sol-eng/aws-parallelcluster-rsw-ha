# Build custom AMI 

1. Make sure you have read/write access to a S3 bucket where you can store transient data and scripts. Replace occurrence of `s3://hpc-scripts1234` with the actual S3 bucket reference in `install-image.sh`, `image-config.yaml` and `install-r.sh`. 
2. Check versions in `install-image.sh`
3. Finally, run 
```
./build-image.sh <IMAGENAME> <BUCKETNAME>
```
where `<IMAGENAME>` is the desired name of the new AMI and `<BUCKETNAME>` the name of the S3 bucket, e.g. `hpc-scripts1234`.

# Useful for debugging 

## Creating your own S3 bucket 

```
aws s3api create-bucket --bucket <BUCKETNAME> --region <REGION> --create-bucket-configuration LocationConstraint=<REGION>
```

where `<BUCKETNAME>` is the desired name of the s3 bucket and `<REGION>` the region intended for use. 

## Cleanup 

If you want to get rid of all AVAILABLE images, run

```
for i in `pcluster list-images --image-status AVAILABLE | grep imageId | awk '{print $2}' | sed 's#"##g' | sed 's#,##'`; do pcluster delete-image -i $i ; done
```

## Get information about image 

```
pcluster describe-image -i <IMAGENAME>
pcluster  list-image-log-streams -i <IMAGENAME>
pcluster get-image-log-events  -i <IMAGENAME> --log-stream-name <AWSPCVERSION>/1
```

where `<AWSPCVERSION>` is the version of AWS parallelcluster used (e.g. 3.11.1)  
