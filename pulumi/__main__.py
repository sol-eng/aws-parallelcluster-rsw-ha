"""An AWS Python Pulumi program"""

import hashlib
import json
from dataclasses import dataclass, field

import jinja2
import pulumi
from pulumi_aws import (
    acm,
    directoryservice,
    ec2,
    iam,
    lb,
    rds,
    route53,
    s3,
    secretsmanager,
)
from pulumi_command import remote
from pulumi_random import RandomPassword, RandomUuid
from pulumi_tls import PrivateKey

# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------


@dataclass
class ConfigValues:
    """A single object to manage all config files."""

    config: pulumi.Config = field(default_factory=lambda: pulumi.Config())
    email: str = field(init=False)
    billing_code: str = field(init=False)

    def __post_init__(self):
        self.email = self.config.require("email")
        self.domain_name = self.config.require("domain_name")
        self.aws_region = self.config.require("region")
        self.rsw_db_username = self.config.require("rsw_db_username")
        self.slurm_db_username = self.config.require("slurm_db_username")
        self.ServerInstanceType = self.config.require("ServerInstanceType")
        self.billing_code = self.config.require("billing_code")
        # DNS / TLS: records are created as <stack>[-ext].<dns_subdomain>.<dns_zone>
        self.dns_zone = self.config.require("dns_zone")
        self.dns_subdomain = self.config.get("dns_subdomain") or ""
        self.dns_suffix = ".".join(x for x in [self.dns_subdomain, self.dns_zone] if x)
        self.acm_domain = self.config.get("acm_domain") or f"*.{self.dns_suffix}"
        self.vpc_name_tag = self.config.get("vpc_name_tag") or "shared"
        self.jumphost_instance_profile: str | None = (
            self.config.get("jumphost_instance_profile") or None
        )
        self.jumphost_ubuntu = self.config.get("jumphost_ubuntu") or "noble"
        # Posit Workbench license: a key (Pulumi secret) or a path to a .lic file
        self.pwb_license_key = self.config.get_secret("pwb_license_key")
        self.pwb_license_file = self.config.get("pwb_license_file") or None


def create_template(path: str) -> jinja2.Template:
    with open(path, "r") as f:
        template = jinja2.Template(f.read())
    return template


def hash_file(path: str) -> pulumi.Output:
    with open(path, mode="r") as f:
        text = f.read()
    hash_str = hashlib.sha224(bytes(text, encoding="utf-8")).hexdigest()
    return pulumi.Output.concat(hash_str)


def get_password(name: str, length: int = 16):
    return RandomPassword(
        name, length=length, special=False, min_lower=1, min_numeric=1, min_upper=1
    ).result


def make_server(
    name: str,
    srvtype: str,
    tags: dict,
    vpc_group_ids: list[str],
    subnet_id: str,
    instance_type: str,
    ami: str,
    key_name: str,
    instance_profile: str | None = None,
):
    # Stand up a server.
    server = ec2.Instance(
        f"{srvtype}-{name}",
        instance_type=instance_type,
        vpc_security_group_ids=vpc_group_ids,
        ami=ami,
        tags=tags,
        subnet_id=subnet_id,
        key_name=key_name,
        iam_instance_profile=instance_profile,
        associate_public_ip_address=False,
        metadata_options={
            "http_put_response_hop_limit": 1,
            "http_tokens": "required",
        },
    )

    # Export final pulumi variables.
    pulumi.export(f"{srvtype}_{name}_private_ip", server.private_ip)
    pulumi.export(f"{srvtype}_{name}_private_dns", server.private_dns)

    return server


def main():
    config = ConfigValues()

    tags = {
        "rs:environment": "development",
        "rs:owner": config.email,
        "rs:project": "solutions",
        "rs:subsystem": config.billing_code,
    }

    pulumi.export("billing_code", config.billing_code)
    pulumi.export("email", config.email)
    pulumi.export("ad_domain", config.domain_name)

    # --------------------------------------------------------------------------
    # Print Pulumi stack name for better visibility
    # --------------------------------------------------------------------------

    stack_name = pulumi.get_stack()
    pulumi.export("stack_name", stack_name)

    # --------------------------------------------------------------------------
    # Pulumi secrets
    # --------------------------------------------------------------------------

    posit_user_pass = get_password("posit_user_pass", length=20)
    pulumi.export("posit_user_pass", pulumi.Output.secret(posit_user_pass))
    posit_user_pass_secret = secretsmanager.Secret(f"PositUserPassword-{stack_name}")
    secretsmanager.SecretVersion(
        f"PositUserPassword-{stack_name}",
        secret_id=posit_user_pass_secret.id,
        secret_string=posit_user_pass,
    )

    pulumi.export("posit_user_pass_arn", posit_user_pass_secret.arn)

    secure_cookie_key = RandomUuid("secure_cookie_key")
    pulumi.export("secure_cookie_key", pulumi.Output.secret(secure_cookie_key.id))

    # --------------------------------------------------------------------------
    # Set up keys.
    # --------------------------------------------------------------------------

    key_pair_name = f"{config.email}-keypair-for-pulumi-{stack_name}"

    #    ssh_key = PrivateKey(key_pair_name,
    #        algorithm="ED25519"
    #    )

    ssh_key = PrivateKey(key_pair_name, algorithm="RSA")

    # Export the public key in OpenSSH format
    pulumi.export("public_key_ssh", ssh_key.public_key_openssh)

    # Optionally, export the private key (be cautious with this)
    pulumi.export("private_key_ssh", pulumi.Output.secret(ssh_key.private_key_openssh))

    key_pair = ec2.KeyPair(
        "pcluster-deployment",
        key_name=key_pair_name,
        public_key=ssh_key.public_key_openssh,
    )

    pulumi.export("key_pair id", key_pair.key_name)

    # --------------------------------------------------------------------------
    # Set up S3 bucket to store scripts for parallelcluster
    # --------------------------------------------------------------------------

    s3bucket = s3.Bucket(
        "hpc-scripts-" + stack_name,
        acl="private",
        force_destroy=True,
        tags=tags
        | {
            "AWS Parallelcluster Name": stack_name,
            "Name": "hpc-scripts-" + stack_name,
        },
    )

    pulumi.export("s3_bucket_id", s3bucket.id)

    #################################################
    # VPC
    #################################################

    # An existing VPC is used. It is looked up by its Name tag and must have
    # subnets whose Name tags contain "public" and "private" respectively.
    vpc = ec2.get_vpc(
        filters=[ec2.GetVpcFilterArgs(name="tag:Name", values=[config.vpc_name_tag])]
    )

    public_subnets = ec2.get_subnets(
        filters=[
            ec2.GetSubnetsFilterArgs(name="vpc-id", values=[vpc.id]),
            ec2.GetSubnetsFilterArgs(name="tag:Name", values=["*public*"]),
        ]
    )

    # Export the subnet IDs
    pulumi.export("public_subnet_ids", public_subnets.ids)

    private_subnets = ec2.get_subnets(
        filters=[
            ec2.GetSubnetsFilterArgs(name="vpc-id", values=[vpc.id]),
            ec2.GetSubnetsFilterArgs(name="tag:Name", values=["*private*"]),
        ]
    )

    # Export the subnet IDs
    pulumi.export("private_subnet_ids", private_subnets.ids)

    # SimpleAD needs exactly two subnets in different AZs: take the first
    # private subnet of each AZ, preserving the original order.
    ad_subnet_ids = []
    seen_azs = set()
    for subnet_id in private_subnets.ids:
        az = ec2.get_subnet(id=subnet_id).availability_zone
        if az not in seen_azs:
            seen_azs.add(az)
            ad_subnet_ids.append(subnet_id)
        if len(ad_subnet_ids) == 2:
            break

    # --------------------------------------------------------------------------
    # ELB access from within AWS ParallelCluster
    # --------------------------------------------------------------------------

    policy = iam.Policy(
        "elbaccess",
        path="/",
        description="Register/deregister login nodes with the Workbench ALB target groups",
        policy=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Action": [
                            "elasticloadbalancing:DescribeTags",
                            "elasticloadbalancing:DescribeTargetGroups",
                            "elasticloadbalancing:DescribeLoadBalancers",
                            "elasticloadbalancing:DescribeTargetHealth",
                            "elasticloadbalancing:RegisterTargets",
                            "elasticloadbalancing:DeregisterTargets",
                        ],
                        "Effect": "Allow",
                        "Resource": "*",
                    },
                    {
                        "Action": [
                            "ec2:DescribeNetworkInterfaces",
                            "ec2:DescribeSubnets",
                            "ec2:DescribeInstances",
                        ],
                        "Effect": "Allow",
                        "Resource": "*",
                    },
                ],
            }
        ),
    )

    pulumi.export("iam_elb_access", policy.arn)

    # --------------------------------------------------------------------------
    # Allow headnote to start nodes via ec2:RunInstances
    # --------------------------------------------------------------------------

    policy = iam.Policy(
        "ec2_runinstances",
        path="/",
        description="Allow headnode of parallelcluster to start nodes",
        policy=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Action": ["ec2:RunInstances"],
                        "Effect": "Allow",
                        "Resource": "*",
                    }
                ],
            }
        ),
    )

    pulumi.export("iam_ec2_runinstances", policy.arn)

    # --------------------------------------------------------------------------
    # S3 access from login nodes
    # --------------------------------------------------------------------------

    policy = iam.Policy(
        "s3access",
        path="/",
        description="S3 Access from login nodes of parallelcluster",
        policy=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Action": [
                            "s3:Get*",
                            "s3:List*",
                            "s3:Describe*",
                            "s3-object-lambda:Get*",
                            "s3-object-lambda:List*",
                        ],
                        "Effect": "Allow",
                        "Resource": "*",
                    }
                ],
            }
        ),
    )

    pulumi.export("iam_s3_access", policy.arn)

    # --------------------------------------------------------------------------
    # Make security group for Posit Workbench
    # --------------------------------------------------------------------------

    rsw_security_group = ec2.SecurityGroup(
        "WorkbenchServerHTTPS",
        description="Security group for WorkbenchServer access (HTTPS and launcher port 5559)",
        ingress=[
            {
                "protocol": "TCP",
                "from_port": 443,
                "to_port": 443,
                "cidr_blocks": [vpc.cidr_block],
                "description": "WorkbenchServer access",
            },
            {
                "protocol": "TCP",
                "from_port": 5559,
                "to_port": 5559,
                "cidr_blocks": [vpc.cidr_block],
                "description": "Launcher access",
            },
        ],
        egress=[
            {
                "protocol": "All",
                "from_port": 0,
                "to_port": 0,
                "cidr_blocks": ["0.0.0.0/0"],
                "description": "Allow all outbound traffic",
            },
        ],
        tags=tags,
        vpc_id=vpc.id,
    )
    pulumi.export("rsw_security_group_https", rsw_security_group.id)

    rsw_security_group = ec2.SecurityGroup(
        "WorkbenchServerNOHTTPS",
        description="Security group for WorkbenchServer access (workbench port 8787 and launcher port 5559)",
        ingress=[
            {
                "protocol": "TCP",
                "from_port": 8787,
                "to_port": 8787,
                "cidr_blocks": [vpc.cidr_block],
                "description": "WorkbenchServer access",
            },
            {
                "protocol": "TCP",
                "from_port": 5559,
                "to_port": 5559,
                "cidr_blocks": [vpc.cidr_block],
                "description": "Launcher access",
            },
        ],
        egress=[
            {
                "protocol": "All",
                "from_port": 0,
                "to_port": 0,
                "cidr_blocks": ["0.0.0.0/0"],
                "description": "Allow all outbound traffic",
            },
        ],
        tags=tags,
        vpc_id=vpc.id,
    )
    pulumi.export("rsw_security_group_nohttps", rsw_security_group.id)

    # --------------------------------------------------------------------------
    # Posit Workbench DB (PostgreSQL)
    # --------------------------------------------------------------------------

    rsw_security_group_db = ec2.SecurityGroup(
        "postgres",
        description="Security group for PostgreSQL access",
        ingress=[
            {
                "protocol": "TCP",
                "from_port": 5432,
                "to_port": 5432,
                "cidr_blocks": [vpc.cidr_block],
                "description": "PostgreSQL DB",
            }
        ],
        egress=[
            {
                "protocol": "All",
                "from_port": 0,
                "to_port": 0,
                "cidr_blocks": ["0.0.0.0/0"],
                "description": "Allow all outbound traffic",
            },
        ],
        tags=tags,
        vpc_id=vpc.id,
    )
    pulumi.export("rsw_security_group_db", rsw_security_group_db.id)

    subnetgroup = rds.SubnetGroup(
        "postgresdbsubnetgroup",
        subnet_ids=private_subnets.ids,
        tags={
            "Name": "Postgres subnet group",
        },
    )

    # Default DB

    rsw_db_pass = get_password("rsw_db_pass")
    pulumi.export("rsw_db_pass", pulumi.Output.secret(rsw_db_pass))

    rsw_db = rds.Instance(
        "rsw-db",
        instance_class="db.t4g.micro",
        allocated_storage=5,
        backup_retention_period=7,
        username=config.rsw_db_username,
        password=rsw_db_pass,
        db_name="pwb",
        engine="postgres",
        publicly_accessible=False,
        skip_final_snapshot=True,
        tags=tags | {"Name": "pwb-db"},
        vpc_security_group_ids=[rsw_security_group_db.id],
        db_subnet_group_name=subnetgroup,
        storage_encrypted=True,
        performance_insights_enabled=True,  # TODO: Update pro-actively to Database Insights standard
        copy_tags_to_snapshot=True,
    )
    pulumi.export("rsw_db_port", rsw_db.port)
    pulumi.export("rsw_db_address", rsw_db.address)
    pulumi.export("rsw_db_endpoint", rsw_db.endpoint)
    pulumi.export("rsw_db_name", rsw_db.db_name)
    pulumi.export("rsw_db_user", config.rsw_db_username)

    # Audit DB

    rsw_audit_db_pass = get_password("rsw_audit_db_pass")
    pulumi.export("rsw_audit_db_pass", pulumi.Output.secret(rsw_audit_db_pass))

    rsw_audit_db = rds.Instance(
        "rsw-audit-db",
        instance_class="db.t4g.micro",
        allocated_storage=5,
        backup_retention_period=7,
        username=config.rsw_db_username,
        password=rsw_audit_db_pass,
        db_name="audit",
        engine="postgres",
        publicly_accessible=False,
        skip_final_snapshot=True,
        tags=tags | {"Name": "pwb-audit-db"},
        vpc_security_group_ids=[rsw_security_group_db.id],
        db_subnet_group_name=subnetgroup,
        storage_encrypted=True,
        performance_insights_enabled=True,  # TODO: Update pro-actively to Database Insights standard
        copy_tags_to_snapshot=True,
    )
    pulumi.export("rsw_audit_db_port", rsw_audit_db.port)
    pulumi.export("rsw_audit_db_address", rsw_audit_db.address)
    pulumi.export("rsw_audit_db_endpoint", rsw_audit_db.endpoint)
    pulumi.export("rsw_audit_db_name", rsw_audit_db.db_name)
    pulumi.export("rsw_audit_db_user", config.rsw_db_username)

    # --------------------------------------------------------------------------
    # SLURM Accounting DB (MySQL)
    # --------------------------------------------------------------------------

    slurm_security_group_db = ec2.SecurityGroup(
        "mysql",
        description="Security group for MySQL access",
        ingress=[
            {
                "protocol": "TCP",
                "from_port": 3306,
                "to_port": 3306,
                "cidr_blocks": [vpc.cidr_block],
                "description": "MySQL DB",
            }
        ],
        egress=[
            {
                "protocol": "All",
                "from_port": 0,
                "to_port": 0,
                "cidr_blocks": ["0.0.0.0/0"],
                "description": "Allow all outbound traffic",
            },
        ],
        tags=tags,
        vpc_id=vpc.id,
    )
    pulumi.export("slurm_security_group_db", slurm_security_group_db.id)

    slurm_db_pass = get_password("slurm_db_pass")
    pulumi.export("slurm_db_pass", pulumi.Output.secret(slurm_db_pass))

    secret = secretsmanager.Secret(f"SlurmDBPassword-{stack_name}")
    slurm_db_pass_sec = secretsmanager.SecretVersion(
        f"SlurmDBPassword-{stack_name}",
        secret_id=secret.id,
        secret_string=slurm_db_pass,
    )
    pulumi.export("slurm_db_pass_arn", slurm_db_pass_sec.arn)

    mysql_param_group = rds.ParameterGroup(
        "mysql-encryption-param-group",
        family="mysql8.4",  # adjust to your MySQL version
        description="Custom MySQL parameter group enforcing encryption in transit",
        parameters=[
            rds.ParameterGroupParameterArgs(
                name="require_secure_transport",
                value="1",
            ),
        ],
    )

    slurm_db = rds.Instance(
        "slurm-db",
        instance_class="db.t4g.medium",
        allocated_storage=5,
        backup_retention_period=7,
        username=config.slurm_db_username,
        password=slurm_db_pass,
        db_name="slurm",
        engine="mysql",
        engine_version="8.4",  # must match the parameter group family above
        publicly_accessible=False,
        skip_final_snapshot=True,
        tags=tags | {"Name": "slurm-db"},
        vpc_security_group_ids=[slurm_security_group_db.id],
        db_subnet_group_name=subnetgroup,
        parameter_group_name=mysql_param_group.name,
        performance_insights_enabled=True,
        performance_insights_retention_period=7,
        storage_encrypted=True,
        copy_tags_to_snapshot=True,
    )

    pulumi.export("slurm_db_port", slurm_db.port)
    pulumi.export("slurm_db_address", slurm_db.address)
    pulumi.export("slurm_db_endpoint", slurm_db.endpoint)
    pulumi.export("slurm_db_name", slurm_db.db_name)
    pulumi.export("slurm_db_user", config.slurm_db_username)

    # --------------------------------------------------------------------------
    # Active Directory (SimpleAD)
    # --------------------------------------------------------------------------

    ad_password = get_password("ad_password")
    pulumi.export("ad_password", pulumi.Output.secret(ad_password))

    secret = secretsmanager.Secret(f"SimpleADPassword-{stack_name}")
    ad_password_sec = secretsmanager.SecretVersion(
        f"SimpleADPassword-{stack_name}", secret_id=secret.id, secret_string=ad_password
    )
    pulumi.export("ad_password_arn", ad_password_sec.arn)

    # --------------------------------------------------------------------------
    # Posit Workbench license, read by the login nodes at boot (config-login.sh)
    # --------------------------------------------------------------------------

    def license_json(key):
        if key and config.pwb_license_file:
            raise ValueError("Set only one of pwb_license_key and pwb_license_file")
        if key:
            return json.dumps({"type": "key", "value": key})
        if config.pwb_license_file:
            with open(config.pwb_license_file) as f:
                return json.dumps({"type": "file", "value": f.read()})
        return json.dumps({"type": "none"})

    license_value = pulumi.Output.secret(
        pulumi.Output.from_input(config.pwb_license_key or "").apply(license_json)
    )

    license_secret = secretsmanager.Secret(f"PwbLicense-{stack_name}")
    secretsmanager.SecretVersion(
        f"PwbLicense-{stack_name}",
        secret_id=license_secret.id,
        secret_string=license_value,
    )
    pulumi.export("pwb_license_secret_arn", license_secret.arn)

    license_policy = iam.Policy(
        "pwb-license-read",
        path="/",
        description="Read the Posit Workbench license secret (login nodes)",
        policy=license_secret.arn.apply(
            lambda arn: json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Action": ["secretsmanager:GetSecretValue"],
                            "Effect": "Allow",
                            "Resource": arn,
                        }
                    ],
                }
            )
        ),
    )
    pulumi.export("iam_license_access", license_policy.arn)

    ad = directoryservice.Directory(
        "pwb_directory",
        name=config.domain_name,
        password=ad_password,
        # edition="Standard",
        type="SimpleAD",
        size="Small",
        description="Directory for PWB environment",
        vpc_settings=directoryservice.DirectoryVpcSettingsArgs(
            vpc_id=vpc.id,
            subnet_ids=ad_subnet_ids,
        ),
        tags=tags | {"Name": f"pwb-directory-{stack_name}"},
    )
    pulumi.export("ad_dns_1", ad.dns_ip_addresses[0])
    pulumi.export("ad_dns_2", ad.dns_ip_addresses[1])
    pulumi.export("ad_access_url", ad.access_url)

    # --------------------------------------------------------------------------
    # Jump Host (AD)
    # --------------------------------------------------------------------------

    ssh_security_group = ec2.SecurityGroup(
        "ssh",
        description="ssh access ",
        ingress=[
            {
                "protocol": "TCP",
                "from_port": 22,
                "to_port": 22,
                "cidr_blocks": [vpc.cidr_block],
                "description": "SSH",
            },
        ],
        egress=[
            {
                "protocol": "All",
                "from_port": 0,
                "to_port": 0,
                "cidr_blocks": ["0.0.0.0/0"],
                "description": "Allow all outbout traffic",
            },
        ],
        tags=tags,
        vpc_id=vpc.id,
    )
    pulumi.export("ssh_security_group", ssh_security_group.id)

    # Fetch the most recent Ubuntu AMI for the jump host. Changing
    # jumphost_ubuntu on an existing stack replaces the jump host.
    ubuntu_ami_names = {
        "focal": "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*",
        "jammy": "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*",
        "noble": "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*",
    }
    ami = ec2.get_ami(
        most_recent=True,
        owners=["099720109477"],  # Canonical
        filters=[
            {"name": "name", "values": [ubuntu_ami_names[config.jumphost_ubuntu]]},
            {"name": "architecture", "values": ["x86_64"]},
            {"name": "virtualization-type", "values": ["hvm"]},
        ],
    )

    # Export the AMI ID
    pulumi.export("ami_id", ami.id)

    jump_host = make_server(
        "jump_host",
        "ad",
        tags=tags | {"Name": f"jump-host-ad-{stack_name}"},
        vpc_group_ids=[ssh_security_group.id],
        instance_type=config.ServerInstanceType,
        subnet_id=private_subnets.ids[0],
        ami=ami.id,
        key_name=key_pair.key_name,
        instance_profile=config.jumphost_instance_profile,
    )

    pulumi.export("vpc_public_subnet", public_subnets.ids[0])
    pulumi.export("vpc_private_subnet", private_subnets.ids[0])
    pulumi.export("jump_host_dns", jump_host.private_dns)
    pulumi.export("jump_host_private_ip", jump_host.private_ip)
    pulumi.export("jump_host_instance_id", jump_host.id)

    connection = remote.ConnectionArgs(
        host=jump_host.private_ip,  # host=jump_host.id,
        user="ubuntu",
        # private_key=Path(f"{key_pair.key_name}.pem").read_text()
        private_key=ssh_key.private_key_openssh,
    )

    command_set_environment_variables = remote.Command(
        "set-env",
        create=pulumi.Output.concat(
            'echo "export AD_PASSWD=',
            ad_password,
            '" > .env;\n',
            'echo "export AD_DOMAIN=',
            config.domain_name,
            '" >> .env;\n',
        ),
        connection=connection,
        opts=pulumi.ResourceOptions(depends_on=jump_host),
    )

    # The remote commands below re-run whenever their inputs change (including
    # provider upgrades), so every one of them must be safe to run repeatedly.
    command_install_justfile = remote.Command(
        "install-justfile",
        create="\n".join(
            [
                """[ -x ~/bin/just ] || curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/bin;""",
                """grep -q 'PATH:$HOME/bin' ~/.bashrc || echo 'export PATH="$PATH:$HOME/bin"' >> ~/.bashrc;""",
            ]
        ),
        opts=pulumi.ResourceOptions(depends_on=jump_host),
        connection=connection,
    )

    justfile_asset = pulumi.FileAsset("server-side-files/justfile")
    command_copy_justfile = remote.CopyToRemote(
        "copy-justfile",
        source=justfile_asset,
        remote_path="justfile",
        connection=connection,
        opts=pulumi.ResourceOptions(depends_on=jump_host),
        triggers=[hash_file("server-side-files/justfile")],
    )

    # Copy the server side files
    @dataclass
    class serverSideFile:
        file_in: str
        file_out: str
        template_render_command: pulumi.Output

    server_side_files = [
        serverSideFile(
            "server-side-files/config/krb5.conf",
            "~/krb5.conf",
            pulumi.Output.all().apply(
                lambda x: create_template("server-side-files/config/krb5.conf").render(
                    domain_name=config.domain_name
                )
            ),
        ),
        serverSideFile(
            "server-side-files/config/resolv.conf",
            "~/resolv.conf",
            pulumi.Output.all(
                config.domain_name, ad.dns_ip_addresses, config.aws_region
            ).apply(
                lambda x: create_template(
                    "server-side-files/config/resolv.conf"
                ).render(domain_name=x[0], dns1=x[1][0], dns2=x[1][1], aws_region=x[2])
            ),
        ),
        serverSideFile(
            "server-side-files/config/create-users.exp",
            "~/create-users.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template(
                    "server-side-files/config/create-users.exp"
                ).render(domain_name=x[0], ad_password=x[1])
            ),
        ),
        serverSideFile(
            "server-side-files/config/create-group.exp",
            "~/create-group.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template(
                    "server-side-files/config/create-group.exp"
                ).render(domain_name=x[0], ad_password=x[1])
            ),
        ),
        serverSideFile(
            "server-side-files/config/add-group-member.exp",
            "~/add-group-member.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template(
                    "server-side-files/config/add-group-member.exp"
                ).render(domain_name=x[0], ad_password=x[1])
            ),
        ),
        serverSideFile(
            "server-side-files/config/useradd.sh",
            "~/useradd.sh",
            pulumi.Output.all(config.domain_name, ad_password, posit_user_pass).apply(
                lambda x: create_template("server-side-files/config/useradd.sh").render(
                    domain_name=x[0], ad_password=x[1], user_pass=x[2]
                )
            ),
        ),
    ]

    command_copy_config_files = []
    for f in server_side_files:
        command_copy_config_files.append(
            remote.Command(
                f"copy {f.file_out} server",
                create=pulumi.Output.concat(
                    'echo "', f.template_render_command, f'" > {f.file_out}'
                ),
                connection=connection,
                triggers=[hash_file(f.file_in)],
                opts=pulumi.ResourceOptions(depends_on=jump_host),
            )
        )

    remote.Command(
        "build-jump-host",
        # create="alias just='/home/ubuntu/bin/just'; just build-rsw",
        create="""export PATH="$PATH:$HOME/bin"; just integrate-ad""",
        connection=connection,
        opts=pulumi.ResourceOptions(
            depends_on=[
                jump_host,
                command_set_environment_variables,
                command_install_justfile,
                command_copy_justfile,
            ]
            + command_copy_config_files
        ),
    )

    #########################################################################
    # Section: Public Load Balancer
    # Date: 2024-12-13
    #########################################################################

    # Security group for the public ALB
    alb_sg = ec2.SecurityGroup(
        f"pwb-alb-sg-{stack_name}",
        description="Security group for public ALB",
        vpc_id=vpc.id,
        ingress=[
            ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=443,
                to_port=443,
                cidr_blocks=["0.0.0.0/0"],
                description="Allow HTTPS from anywhere",
            ),
            ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=8787,
                to_port=8787,
                cidr_blocks=["0.0.0.0/0"],
                description="Allow TCP 8787 from anywhere",
            ),
        ],
        egress=[
            ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
                description="Allow all outbound traffic",
            )
        ],
        tags=tags | {"Name": f"pwb-alb-sg-{stack_name}"},
    )


    # Create an internal and public(ext) Application Load Balancer
    pwb_alb_ext = lb.LoadBalancer(
        f"pwb-alb-ext-{stack_name}",
        name=f"pwb-alb-ext-{stack_name}",
        internal=False,  # This makes it a public-facing ALB
        load_balancer_type="application",
        security_groups=[alb_sg.id],
        subnets=public_subnets.ids,  # Place it in public subnets
        tags=tags | {"Name": f"pwb-alb-ext-{stack_name}"},
        opts=pulumi.ResourceOptions(delete_before_replace=True),
    )
    pulumi.export("pwb_alb_ext_arn", pwb_alb_ext.arn)
    pulumi.export("pwb_alb_ext_dns_name", pwb_alb_ext.dns_name)

    pwb_alb_int = lb.LoadBalancer(
        f"pwb-alb-int-{stack_name}",
        name=f"pwb-alb-int-{stack_name}",
        internal=True,
        load_balancer_type="application",
        security_groups=[alb_sg.id],
        subnets=public_subnets.ids,  # Place it in public subnets
        tags=tags | {"Name": f"pwb-alb-int-{stack_name}"},
        opts=pulumi.ResourceOptions(delete_before_replace=True),
    )
    pulumi.export("pwb_alb_int_arn", pwb_alb_int.arn)
    pulumi.export("pwb_alb_int_dns_name", pwb_alb_int.dns_name)

    # Get the ACM certificate
    cert = acm.get_certificate(
        domain=config.acm_domain, most_recent=True, statuses=["ISSUED"]
    )

    # Create a target group for the ALB.
    # The head node will register itself with this target group.
    alb_target_group_ext = lb.TargetGroup(
        f"pwb-alb-tg-ext-{stack_name}",
        port=8787,  # The internal service port
        protocol="HTTP",
        vpc_id=vpc.id,
        target_type="ip",
        stickiness=lb.TargetGroupStickinessArgs(
            type="app_cookie",
            cookie_name="rs-csrf-token",
            enabled=True,
        ),
        health_check=lb.TargetGroupHealthCheckArgs(
            enabled=True,
            protocol="HTTP",
            path="/",
            port="traffic-port",
            matcher="302",  # RStudio Workbench redirects with a 302
        ),
        tags=tags | {"Name": f"pwb-alb-tg-ext-{stack_name}"},
    )
    pulumi.export("alb_target_group_ext_arn", alb_target_group_ext.arn)

    alb_target_group_int = lb.TargetGroup(
        f"pwb-alb-tg-int-{stack_name}",
        port=8787,  # The internal service port
        protocol="HTTP",
        vpc_id=vpc.id,
        target_type="ip",
        stickiness=lb.TargetGroupStickinessArgs(
            type="app_cookie",
            cookie_name="rs-csrf-token",
            enabled=True,
        ),
        health_check=lb.TargetGroupHealthCheckArgs(
            enabled=True,
            protocol="HTTP",
            path="/",
            port="traffic-port",
            matcher="302",  # RStudio Workbench redirects with a 302
        ),
        tags=tags | {"Name": f"pwb-alb-tg-int-{stack_name}"},
    )
    pulumi.export("alb_target_group_int_arn", alb_target_group_int.arn)

    # Create a listener for HTTPS traffic
    alb_listener_ext = lb.Listener(
        f"pwb-alb-listener-ext-{stack_name}",
        load_balancer_arn=pwb_alb_ext.arn,
        port=443,
        protocol="HTTPS",
        certificate_arn=cert.arn,
        default_actions=[
            lb.ListenerDefaultActionArgs(
                type="forward",
                target_group_arn=alb_target_group_ext.arn,
            )
        ],
        tags=tags,
        opts=pulumi.ResourceOptions(
            delete_before_replace=True, depends_on=[pwb_alb_ext]
        ),
    )
    pulumi.export("alb_listener_ext_arn", alb_listener_ext.arn)

    alb_listener_int = lb.Listener(
        f"pwb-alb-listener-int-{stack_name}",
        load_balancer_arn=pwb_alb_int.arn,
        port=443,
        protocol="HTTPS",
        certificate_arn=cert.arn,
        default_actions=[
            lb.ListenerDefaultActionArgs(
                type="forward",
                target_group_arn=alb_target_group_int.arn,
            )
        ],
        tags=tags,
        opts=pulumi.ResourceOptions(
            delete_before_replace=True, depends_on=[pwb_alb_int]
        ),
    )
    pulumi.export("alb_listener_int_arn", alb_listener_int.arn)

    # --------------------------------------------------------------------------
    # Route53: <stack>.<dns_suffix> (internal) and <stack>-ext.<dns_suffix>
    # --------------------------------------------------------------------------

    dns_zone = route53.get_zone(name=config.dns_zone)

    dns_record_ext = route53.Record(
        "pwb-dns-record-ext",
        zone_id=dns_zone.id,
        name=f"{stack_name}-ext.{config.dns_suffix}",
        type="A",
        aliases=[
            route53.RecordAliasArgs(
                name=pwb_alb_ext.dns_name,
                zone_id=pwb_alb_ext.zone_id,
                evaluate_target_health=True,
            )
        ],
        opts=pulumi.ResourceOptions(
            delete_before_replace=True, depends_on=[pwb_alb_ext]
        ),
    )

    pulumi.export("pwb_url_ext", dns_record_ext.fqdn)

    dns_record_int = route53.Record(
        "pwb-dns-record-int",
        zone_id=dns_zone.id,
        name=f"{stack_name}.{config.dns_suffix}",
        type="A",
        aliases=[
            route53.RecordAliasArgs(
                name=pwb_alb_int.dns_name,
                zone_id=pwb_alb_int.zone_id,
                evaluate_target_health=True,
            )
        ],
        opts=pulumi.ResourceOptions(
            delete_before_replace=True, depends_on=[pwb_alb_int]
        ),
    )

    pulumi.export("pwb_url_int", dns_record_int.fqdn)


main()
