#!/bin/bash
#
# Print status information for a running cluster: Workbench version, URLs,
# node list and jump host. The cluster name must match the Pulumi stack name.
#
# Usage: ./cluster-stat.sh <clustername> [--show-secrets]

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <clustername> [--show-secrets]" >&2
    exit 1
fi

clustername=$1
show_secrets=false
[ "${2:-}" = "--show-secrets" ] && show_secrets=true

PULUMI_DIR="$(cd "$(dirname "$0")/../pulumi" && pwd)"
stack_output() {
    pulumi stack output -C "$PULUMI_DIR" -s "$clustername" "$@"
}

echo "Information for cluster $clustername"
echo "------------------------------------------"
echo ""
firstnode=$(aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" "Name=tag:parallelcluster:node-type,Values=LoginNode" --query 'Reservations[*].Instances[?State.Name==`running`]' | jq -r '.[] | .[] | .InstanceId' | head -1)

if [ -n "$firstnode" ]; then
    cmdid=$(aws ssm send-command --instance-ids "$firstnode" --document-name "AWS-RunShellScript" --parameters commands="rstudio-server version" --query "Command.CommandId" --output text)
    aws ssm wait command-executed --command-id "$cmdid" --instance-id "$firstnode" || true
    echo "Posit Workbench Version: $(aws ssm get-command-invocation --command-id "$cmdid" --instance-id "$firstnode" --query StandardOutputContent --output text)"
else
    echo "Posit Workbench Version: no running login node found"
fi
echo ""
echo "ALB int URL: https://$(stack_output pwb_url_int)"
echo "ALB ext URL: https://$(stack_output pwb_url_ext)"
echo ""
echo "#InstanceID, PrivateDnsName, PublicDnsName, Role"
aws ec2 describe-instances --filters "Name=tag:parallelcluster:cluster-name,Values=$clustername" --query 'Reservations[*].Instances[?State.Name==`running`]' | jq -r '.[] | .[] | [.InstanceId,.PrivateDnsName,.PublicDnsName,(.Tags | .[] | (select(.Key=="parallelcluster:node-type")) | .Value)] | @csv'
echo ""
echo "Jump Host: $(stack_output jump_host_dns)"
echo ""

if $show_secrets; then
    echo "Posit User Password: $(stack_output --show-secrets posit_user_pass)"
    echo ""
    echo "private ssh key for ubuntu user:"
    stack_output --show-secrets private_key_ssh
else
    echo "Run with --show-secrets to print the posit user password and SSH key."
fi
