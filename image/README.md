# Build custom AMI 

1. Make sure you have read/write access to a S3 bucket. Replace occurrence of `s3://hpc-scripts1234` with the actual S3 bucket reference in `install-image.sh`, `image-config.yaml` and `install-r.sh`. 
2. Check versions in `install-image.sh`
3. Finally, run 
```
./build-image.sh <IMAGENAME>
```
where `<IMAGENAME>` is the desired name of the new AMI.

# Useful for debugging 

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
