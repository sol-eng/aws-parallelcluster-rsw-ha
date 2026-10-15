#!/bin/bash
#
# Render the cluster config and node scripts from the Pulumi stack outputs,
# upload the scripts to S3 and create the ParallelCluster cluster.
#
# Usage: ./deploy.sh envs/<name>.env [--dry-run]
#
#   --dry-run   render into tmp/ and validate with 'pcluster create-cluster
#               --dryrun true', but don't upload or create anything
#
# Set KEEP_TMP=1 to keep the rendered files in tmp/ after a real deployment
# (they contain database passwords).

set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 envs/<name>.env [--dry-run]" >&2
    exit 1
}

[ $# -ge 1 ] || usage
ENV_FILE=$1
DRY_RUN=false
if [ "${2:-}" = "--dry-run" ]; then DRY_RUN=true; elif [ -n "${2:-}" ]; then usage; fi
[ -f "$ENV_FILE" ] || { echo "ERROR: env file $ENV_FILE not found" >&2; exit 1; }

# shellcheck source=envs/demo.env.example
source "$ENV_FILE"

: "${CLUSTERNAME:?must be set in $ENV_FILE}"
: "${REGION:?must be set in $ENV_FILE}"
: "${PWB_VERSION:?must be set in $ENV_FILE}"
: "${HPC_DOMAIN:?must be set in $ENV_FILE}"
: "${HPC_HOST:?must be set in $ENV_FILE}"
: "${ALLOWEDIPS:?must be set in $ENV_FILE}"
STACKNAME=${STACKNAME:-$CLUSTERNAME}
CONFIG=${CONFIG:-default}
APPS_EFS_ID=${APPS_EFS_ID:-}
CERT_SUBJECT=${CERT_SUBJECT:-"/CN=*.$HPC_DOMAIN"}
AMI=${AMI:-}
APPTAINER_VERSION=${APPTAINER_VERSION:-1.5.4}

for flag in SSL SINGULARITY_SUPPORT EASYBUILD_SUPPORT BENCHMARK_SUPPORT LOCAL; do
    value=${!flag:-false}
    if [ "$value" != true ] && [ "$value" != false ]; then
        echo "ERROR: $flag must be 'true' or 'false', got '$value'" >&2
        exit 1
    fi
    printf -v "$flag" '%s' "$value"
done

# Without a custom AMI the official ParallelCluster Ubuntu 24.04 image is used.
# It has no R/Python, so this only works when sessions run in containers.
if [ -z "$AMI" ] && ! $SINGULARITY_SUPPORT; then
    echo "ERROR: AMI is empty. Build a custom AMI (image/build-image.sh), or set" >&2
    echo "       SINGULARITY_SUPPORT=true to use the official ParallelCluster AMI." >&2
    exit 1
fi

TEMPLATE="config/cluster-config-wb.${CONFIG}.tmpl"
[ -f "$TEMPLATE" ] || { echo "ERROR: template $TEMPLATE not found" >&2; exit 1; }
if [ "$CONFIG" = easybuild ] && [ -z "$APPS_EFS_ID" ]; then
    echo "ERROR: CONFIG=easybuild needs APPS_EFS_ID" >&2
    exit 1
fi

for cmd in pulumi jq aws perl pcluster; do
    command -v "$cmd" >/dev/null || {
        echo "ERROR: '$cmd' not found in PATH (pcluster: run 'uv sync' in the repo root and activate .venv)" >&2
        exit 1
    }
done

# ------------------------------------------------------------------------------
# Pulumi outputs
# ------------------------------------------------------------------------------

echo "Reading outputs from Pulumi stack $STACKNAME"
PULUMI_DIR=../pulumi
OUTPUTS=$(pulumi stack output -C "$PULUMI_DIR" -s "$STACKNAME" --json --show-secrets)

# out <name>: print a required stack output, fail if it is missing
out() {
    jq -er --arg k "$1" '.[$k] // empty' <<<"$OUTPUTS" || {
        echo "ERROR: Pulumi output '$1' missing in stack $STACKNAME" >&2
        return 1
    }
}

# ad_domain/email outputs are newer; fall back to the stack config
AD_DOMAIN=$(jq -r '.ad_domain // empty' <<<"$OUTPUTS")
[ -n "$AD_DOMAIN" ] || AD_DOMAIN=$(pulumi config get -C "$PULUMI_DIR" -s "$STACKNAME" domain_name 2>/dev/null || echo "pwb.posit.co")
EMAIL=$(jq -r '.email // empty' <<<"$OUTPUTS")
[ -n "$EMAIL" ] || EMAIL=$(pulumi config get -C "$PULUMI_DIR" -s "$STACKNAME" email)

S3_BUCKETNAME=$(out s3_bucket_id)

if $SSL; then
    SECURITYGROUP_RSW=$(out rsw_security_group_https)
else
    SECURITYGROUP_RSW=$(out rsw_security_group_nohttps)
fi

# Every @@NAME@@ token in the templates is replaced by the value of TPL_NAME
export TPL_PWB_VERSION="$PWB_VERSION"
export TPL_REGION="$REGION"
export TPL_AMI="$AMI"
export TPL_HPC_DOMAIN="$HPC_DOMAIN"
export TPL_HPC_HOST="$HPC_HOST"
export TPL_ALLOWEDIPS="$ALLOWEDIPS"
export TPL_APPS_EFS_ID="$APPS_EFS_ID"
export TPL_APPTAINER_VERSION="$APPTAINER_VERSION"
export TPL_SSL="$SSL"
export TPL_SINGULARITY_SUPPORT="$SINGULARITY_SUPPORT"
export TPL_EASYBUILD_SUPPORT="$EASYBUILD_SUPPORT"
export TPL_BENCHMARK_SUPPORT="$BENCHMARK_SUPPORT"
export TPL_LOCAL="$LOCAL"
export TPL_EMAIL="$EMAIL"
export TPL_AD_DOMAIN="$AD_DOMAIN"
export TPL_AD_BASE_DN="dc=${AD_DOMAIN//./,dc=}"
export TPL_S3_BUCKETNAME="$S3_BUCKETNAME"
export TPL_S3_PREFIX="$S3_BUCKETNAME/$CLUSTERNAME"
export TPL_SECURITYGROUP_RSW="$SECURITYGROUP_RSW"
TPL_AD_DNS=$(out ad_dns_1); export TPL_AD_DNS
TPL_AD_PASSWORD_ARN=$(out ad_password_arn); export TPL_AD_PASSWORD_ARN
TPL_RSW_DB_HOST=$(out rsw_db_address); export TPL_RSW_DB_HOST
TPL_RSW_DB_USER=$(out rsw_db_user); export TPL_RSW_DB_USER
TPL_RSW_DB_PASS=$(out rsw_db_pass); export TPL_RSW_DB_PASS
TPL_RSW_AUDIT_DB_HOST=$(out rsw_audit_db_address); export TPL_RSW_AUDIT_DB_HOST
TPL_RSW_AUDIT_DB_USER=$(out rsw_audit_db_user); export TPL_RSW_AUDIT_DB_USER
TPL_RSW_AUDIT_DB_PASS=$(out rsw_audit_db_pass); export TPL_RSW_AUDIT_DB_PASS
TPL_SLURM_DB_HOST=$(out slurm_db_endpoint); export TPL_SLURM_DB_HOST
TPL_SLURM_DB_NAME=$(out slurm_db_name); export TPL_SLURM_DB_NAME
TPL_SLURM_DB_USER=$(out slurm_db_user); export TPL_SLURM_DB_USER
TPL_SLURM_DB_PASS_ARN=$(out slurm_db_pass_arn); export TPL_SLURM_DB_PASS_ARN
TPL_SECURE_COOKIE_KEY=$(out secure_cookie_key); export TPL_SECURE_COOKIE_KEY
TPL_BILLING_CODE=$(out billing_code); export TPL_BILLING_CODE
TPL_ELB_ACCESS=$(out iam_elb_access); export TPL_ELB_ACCESS
TPL_S3_ACCESS=$(out iam_s3_access); export TPL_S3_ACCESS
TPL_EC2_RUNINSTANCES=$(out iam_ec2_runinstances); export TPL_EC2_RUNINSTANCES
TPL_SUBNETID=$(out vpc_private_subnet); export TPL_SUBNETID
TPL_SECURITYGROUP_SSH=$(out ssh_security_group); export TPL_SECURITYGROUP_SSH
TPL_PWB_URL_INT=$(out pwb_url_int); export TPL_PWB_URL_INT

# render <in> <out>: replace @@NAME@@ tokens literally, fail on unknown tokens
render() {
    perl -pe 's/@@([A-Z0-9_]+)@@/exists $ENV{"TPL_$1"} ? $ENV{"TPL_$1"} : die "ERROR: no value for token \@\@$1\@\@ in $ARGV\n"/ge' "$1" > "$2"
}

# ------------------------------------------------------------------------------
# Optional self-signed certificate (SSL=true)
# ------------------------------------------------------------------------------

if $SSL; then
    mkdir -p certs
    if [ -f "certs/$HPC_DOMAIN.crt" ] && [ -f "certs/$HPC_DOMAIN.key" ]; then
        echo "Using existing certs/$HPC_DOMAIN.{crt,key}"
    else
        echo "Generating self-signed SSL certificate for *.$HPC_DOMAIN"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "certs/$HPC_DOMAIN.key" -out "certs/$HPC_DOMAIN.crt" \
            -subj "$CERT_SUBJECT"
    fi
fi

# ------------------------------------------------------------------------------
# Render
# ------------------------------------------------------------------------------

echo "Rendering scripts and cluster config into tmp/"
rm -rf tmp
mkdir -p tmp
chmod 700 tmp
if ! $DRY_RUN && [ -z "${KEEP_TMP:-}" ]; then
    trap 'rm -rf tmp' EXIT
fi

UPLOADS=(install-pwb-config.sh config-login.sh config-compute.sh)
for f in "${UPLOADS[@]}"; do
    render "scripts/$f" "tmp/$f"
done
render "$TEMPLATE" tmp/cluster-config-wb.yaml
if [ -z "$AMI" ]; then
    echo "No AMI set: using the official ParallelCluster ubuntu2404 image"
    sed -i.bak '/^  CustomAmi: *$/d' tmp/cluster-config-wb.yaml && rm -f tmp/cluster-config-wb.yaml.bak
fi
if $SSL; then
    cp "certs/$HPC_DOMAIN.crt" "certs/$HPC_DOMAIN.key" tmp/
    UPLOADS+=("$HPC_DOMAIN.crt" "$HPC_DOMAIN.key")
fi

PCLUSTER_ARGS=(--suppress-validators ALL --cluster-name="$CLUSTERNAME" --cluster-config=tmp/cluster-config-wb.yaml --rollback-on-failure false)

if $DRY_RUN; then
    echo "Validating cluster config (dry run)"
    pcluster create-cluster "${PCLUSTER_ARGS[@]}" --dryrun true
    echo "Dry run done. Rendered files (with secrets) are in $(pwd)/tmp - delete them when done."
    exit 0
fi

# ------------------------------------------------------------------------------
# Upload and deploy
# ------------------------------------------------------------------------------

echo "Uploading scripts to s3://$TPL_S3_PREFIX/"
for f in "${UPLOADS[@]}"; do
    aws s3 cp --only-show-errors "tmp/$f" "s3://$TPL_S3_PREFIX/$f"
done

echo "Creating cluster $CLUSTERNAME"
pcluster create-cluster "${PCLUSTER_ARGS[@]}"
