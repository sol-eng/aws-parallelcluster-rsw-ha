# Cluster deployment

Details: [docs/AWSParallelcluster.qmd](../docs/AWSParallelcluster.qmd).

## Usage

```bash
cp envs/demo.env.example envs/<clustername>.env   # one file per environment, git-ignored
$EDITOR envs/<clustername>.env                    # at least CLUSTERNAME, AMI, REGION
./deploy.sh envs/<clustername>.env --dry-run      # render to tmp/ and validate only
./deploy.sh envs/<clustername>.env
./cluster-stat.sh <clustername> [--show-secrets]
```

`deploy.sh` does the following:
1. Reads the env file.
2. Reads everything else from the Pulumi stack outputs (stack = `STACKNAME`, default `CLUSTERNAME`).
3. Fills the `@@NAME@@` placeholders in the template and scripts.
4. Uploads the scripts to `s3://<bucket>/<clustername>/`.
5. Runs `pcluster create-cluster`.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `config/cluster-config-wb.default.tmpl` | - | Cluster template: head node, login nodes, `interactive`/`all`/`gpu` queues, EFS |
| `config/cluster-config-wb.easybuild.tmpl` | - | Same plus an existing EasyBuild EFS on `/opt/apps` (`APPS_EFS_ID`) |
| `scripts/install-pwb-config.sh` | head node (`OnNodeConfigured`) | Writes the Workbench config to `/opt/rstudio`, builds the session components squashfs image, registers login nodes with the ALBs, writes `rc.pwb` |
| `scripts/config-login.sh` | login nodes (via the `rc.pwb` cron job from the AMI) | Installs and starts Workbench |
| `scripts/config-compute.sh` | compute nodes (`OnNodeConfigured`) | Mounts the Workbench session components (squashfs image built by the head node) |
| `cluster-stat.sh` | your machine | Workbench version, URLs, node list |

Logs: `/var/log/install-pwb-config.log` (head), `/var/log/rc.pwb.log` (login), `/opt/rstudio/config-compute/` (compute). See [docs/Troubleshooting.qmd](../docs/Troubleshooting.qmd).
