# Posit Workbench on AWS ParallelCluster (HA)

A reference deployment of [Posit Workbench](https://posit.co/products/enterprise/workbench/) on [AWS ParallelCluster](https://aws.amazon.com/hpc/parallelcluster/) with Slurm, focused on high availability:

- Workbench runs load-balanced on ParallelCluster **login nodes** behind AWS Application Load Balancers, not on the head node.
- Workbench state lives in **PostgreSQL**; configuration and home directories are on **EFS**.
- Users come from **AWS SimpleAD**.
- Sessions and jobs run on Slurm compute queues (CPU and GPU) via the Slurm Launcher.

Full documentation: <https://sol-eng.github.io/aws-parallelcluster-rsw-ha/>

![Architecture](docs/AWS%20PC.drawio.png)

## Repository layout

| Path | Content |
|---|---|
| [`pulumi/`](pulumi/) | Auxiliary infrastructure: SimpleAD and jump host, RDS databases, ALBs, Route53, S3 bucket, secrets |
| [`image/`](image/) | Custom AMI build (R, Python, Quarto, Apptainer, ...) |
| [`parallelcluster/`](parallelcluster/) | Cluster templates, node scripts and `deploy.sh` |
| [`docs/`](docs/) | Quarto source of the documentation site |

## Prerequisites

- An AWS account with:
  - a VPC with public and private subnets (tagged `*public*` / `*private*`) in at least two AZs, with NAT for the private subnets
  - a Route53 hosted zone
  - an ACM certificate for the Workbench host names
- Network access to the VPC's private subnets (VPN or similar). Pulumi configures the AD jump host over SSH.
- Tools: [uv](https://docs.astral.sh/uv/), [Pulumi](https://www.pulumi.com/docs/install/), [AWS CLI](https://aws.amazon.com/cli/), [just](https://github.com/casey/just), `jq`, `perl`

## Quickstart

```bash
# 0. ParallelCluster CLI (version pinned in pyproject.toml)
uv sync && source .venv/bin/activate

# 1. Auxiliary services; the stack name is the cluster name
cd pulumi
pulumi stack init demo
pulumi config set aws:region eu-west-1
pulumi config set email you@example.com
pulumi config set billing_code my-project
pulumi config set dns_zone example.com
just up                       # pulumi up + create users posit0001..posit0010

# 2. Custom AMI
cd ../image
./build-image.sh demo-image demo
pcluster describe-image -i demo-image | jq -r .ec2AmiInfo.amiId   # once BUILD_COMPLETE

# 3. Cluster
cd ../parallelcluster
cp envs/demo.env.example envs/demo.env   # set AMI=..., review the rest
./deploy.sh envs/demo.env --dry-run
./deploy.sh envs/demo.env
./cluster-stat.sh demo
```

Workbench is then available at `https://demo-ext.<dns_zone>`. Log in as `posit0001` with the password from `pulumi stack output posit_user_pass --show-secrets`.

## Python environments

There are two separate uv projects:

- **The repository root** pins the `aws-parallelcluster` CLI.
- **`pulumi/`** holds the Pulumi program; Pulumi manages it automatically through `toolchain: uv`.

If uv can't find the Python version in `.python-version`, run `uv self update` (install uv with `curl -LsSf https://astral.sh/uv/install.sh | sh`).
