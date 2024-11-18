# Build custom AMI 

1. Make sure you have read/write access to a S3 bucket. Replace occurrence of `s3://hpc-scripts1234` with the actual S3 bucket reference in `install-image.sh`, `image-config.yaml` and `install-r.sh`. 
2. Check versions in `install-image.sh`
3. Finally, run 
```
./build-image.sh <IMAGENAME>
```
where `<IMAGENAME>` is the desired name of the new AMI. 
