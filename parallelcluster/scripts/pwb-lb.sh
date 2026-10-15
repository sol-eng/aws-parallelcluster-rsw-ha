#!/bin/bash
#
# Keep the Workbench load balancing in sync with the login nodes that exist.
# Installed on every login node by config-login.sh as /usr/local/sbin/pwb-lb
# and run by the pwb-lb systemd unit:
#
#   register    (unit start, i.e. boot) register this node with the ALB target
#               groups, then run cleanup
#   deregister  (unit stop, i.e. shutdown) remove this node from the target
#               groups, mark it offline in Workbench and deactivate a
#               key-based Workbench license
#   cleanup     remove ALB targets and Workbench nodes that no longer belong
#               to a running login node of this cluster
#
# A target or Workbench node is only removed if EC2 has no running/pending
# login node with its IP. Workbench nodes additionally have to be reported as
# unreachable by 'rserver-db node-status'. This node is never removed.
#
# Placeholders wrapped in double @ signs are filled in by deploy.sh before upload.

exec >> /var/log/pwb-lb.log 2>&1
echo "---- $(date -u +%FT%TZ) pwb-lb $*"

CLUSTER_NAME="@@CLUSTERNAME@@"
export AWS_DEFAULT_REGION="@@REGION@@"
TARGET_GROUPS="@@ALB_TG_EXT_ARN@@ @@ALB_TG_INT_ARN@@"
PORT=8787
RSERVER_DB=/usr/lib/rstudio-server/bin/rserver-db

imds() {
    local token
    token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

MY_IP=$(imds local-ipv4)
if [ -z "$MY_IP" ]; then
    echo "ERROR: could not determine local IP from instance metadata"
    exit 1
fi

# Space-separated private IPs of all running/pending login nodes, padded with
# spaces for matching; fails if EC2 can't be queried
login_node_ips() {
    local ips
    ips=$(aws ec2 describe-instances \
        --filters "Name=tag:parallelcluster:cluster-name,Values=$CLUSTER_NAME" \
                  "Name=tag:parallelcluster:node-type,Values=LoginNode" \
                  "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[].Instances[].PrivateIpAddress' --output text) || return 1
    echo " $(echo $ips) "
}

register() {
    for tg in $TARGET_GROUPS; do
        aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$MY_IP,Port=$PORT" \
            && echo "Registered $MY_IP:$PORT with $tg"
    done
}

deregister() {
    for tg in $TARGET_GROUPS; do
        aws elbv2 deregister-targets --target-group-arn "$tg" --targets "Id=$MY_IP,Port=$PORT" \
            && echo "Deregistered $MY_IP:$PORT from $tg"
    done
    # Same as 'rstudio-server stop' does: mark this node offline
    [ -x $RSERVER_DB ] && $RSERVER_DB stop-node
    # Give a key-based license activation back, so replacement login nodes
    # don't use up activations (license files need no deactivation)
    if [ -f /var/lib/rstudio-server/.license-activated-by-key ]; then
        /usr/lib/rstudio-server/bin/license-manager deactivate >/dev/null \
            && rm -f /var/lib/rstudio-server/.license-activated-by-key \
            && echo "Workbench license deactivated"
    fi
}

cleanup() {
    local live
    if ! live=$(login_node_ips) || [ -z "${live// /}" ]; then
        echo "WARNING: could not list running login nodes, skipping cleanup"
        return
    fi
    echo "Running login nodes:$live"

    # Stale ALB targets
    for tg in $TARGET_GROUPS; do
        for ip in $(aws elbv2 describe-target-health --target-group-arn "$tg" \
                    --query 'TargetHealthDescriptions[].Target.Id' --output text); do
            case "$live" in
                *" $ip "*) ;;
                *) aws elbv2 deregister-targets --target-group-arn "$tg" --targets "Id=$ip,Port=$PORT" \
                       && echo "Removed stale target $ip from $tg" ;;
            esac
        done
    done

    # Workbench nodes of login nodes that no longer exist
    [ -x $RSERVER_DB ] || return
    command -v jq >/dev/null || apt-get install -y jq
    $RSERVER_DB node-status 2>/dev/null | sed -n '/^{/,$p' \
        | jq -r --arg me "$MY_IP" '.nodes[]? | select(.ipv4 != $me and .reachable == false) | "\(.id) \(.ipv4) \(.sessions | length)"' \
        | while read -r id ip sessions; do
            case "$live" in
                *" $ip "*) echo "Workbench node $id ($ip) is unreachable but its instance is running, keeping it" ;;
                *) echo "Deleting Workbench node $id ($ip), instance gone ($sessions sessions listed)"
                   $RSERVER_DB delete-node "$id" ;;
            esac
        done
}

case "$1" in
    register)   register; cleanup ;;
    deregister) deregister ;;
    cleanup)    cleanup ;;
    *)          echo "Usage: $0 register|deregister|cleanup"; exit 1 ;;
esac
