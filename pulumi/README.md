# Auxiliary infrastructure (Pulumi)

Creates everything the cluster needs around ParallelCluster:
- SimpleAD and an AD-joined jump host
- PostgreSQL databases for Workbench and its audit log, and MySQL for Slurm accounting
- external and internal ALBs with Route53 records
- an S3 bucket, IAM policies, security groups, an EC2 key pair and Secrets Manager secrets

Details: [docs/Pulumi.qmd](../docs/Pulumi.qmd).

## Setup

**The stack name must be the cluster name you deploy later.**

```bash
pulumi stack init <clustername>
pulumi config set aws:region eu-west-1
pulumi config set region eu-west-1
pulumi config set email you@example.com
pulumi config set billing_code my-project
pulumi config set dns_zone example.com
pulumi config set dns_subdomain hpc     # optional: <stack>.hpc.example.com
pulumi config set --secret pwb_license_key XXXX-...   # or: pulumi config set pwb_license_file workbench.lic
just up                                 # pulumi up -y && just create-users
```

Requirements:
- A VPC tagged `Name=<vpc_name_tag>` (default `shared`), with `*public*` and `*private*` subnets in at least two AZs.
- An ISSUED ACM certificate for `*.<dns_subdomain>.<dns_zone>`.
- SSH access (port 22) to the private subnets from where you run Pulumi.

The configuration keys and their defaults are documented in `Pulumi.yaml`.

## Recipes

| Command | What it does |
|---|---|
| `just up` | `pulumi up -y` and create 10 users |
| `just create-users <N>` | create users `posit0001` ... `posit<N>` on the jump host |

## Upgrading an existing stack

Older stacks don't have the new DNS settings. Before running `pulumi up`, set them; `jumphost_ubuntu` and `jumphost_instance_profile` keep the existing jump host:

```bash
pulumi config set dns_zone <zone>                 # e.g. what was hardcoded before
pulumi config set dns_subdomain <subdomain>       # e.g. pcluster
pulumi config set jumphost_ubuntu focal
pulumi config set jumphost_instance_profile <profile-name>
pulumi preview
```
