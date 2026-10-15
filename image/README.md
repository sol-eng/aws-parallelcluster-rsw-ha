# Custom AMI

Builds a ParallelCluster AMI based on the official Ubuntu 24.04 image. It contains:
- R and Python (several versions each)
- Quarto and Apptainer
- system libraries for R packages
- AD integration tools
- the `rc.pwb` cron job that sets up Workbench on login nodes

Details: [docs/AMI.qmd](../docs/AMI.qmd).

## Usage

Run the Pulumi stack first; its S3 bucket, private subnet and SSH security group are used for the build.

```bash
# from the repo root: uv sync && source .venv/bin/activate
./build-image.sh <IMAGENAME> <PULUMI_STACK>
pcluster describe-image -i <IMAGENAME> | jq -r '.imageBuildStatus, .ec2AmiInfo.amiId'
```

Put the AMI ID into `AMI=` in `parallelcluster/envs/<name>.env`.

## Files

| File | Purpose |
|---|---|
| `build-image.sh` | Uploads the scripts to `s3://<bucket>/image/`, renders `image-config.yaml`, starts `pcluster build-image` |
| `image-config.yaml` | Image build config (`@@...@@` placeholders filled by `build-image.sh`) |
| `install-image.sh` | Entry point on the build instance. **All software versions are pinned here.** |
| `install-*.sh`, `run.R` | Individual install steps (R, Python, Quarto, OS deps, Apptainer, NVIDIA, AD tools) |
