"""An AWS Python Pulumi program"""

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List


import jinja2
import pulumi
import json
from pulumi_aws import ec2, rds, directoryservice, secretsmanager, iam, s3
import pulumi_awsx as awsx
from pulumi_command import remote
from pulumi_random import RandomPassword, RandomUuid


# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

@dataclass
class ConfigValues:
    """A single object to manage all config files."""
    config: pulumi.Config = field(default_factory=lambda: pulumi.Config())
    email: str = field(init=False)
    public_key: str = field(init=False)
    billing_code: str = field(init=False)

    def __post_init__(self):
        self.email = self.config.require("email")
        self.ami = self.config.require("ami")
        self.domain_name = self.config.require("domain_name")
        self.aws_region = self.config.require("region")
        self.rsw_db_username = self.config.require("rsw_db_username")
        self.slurm_db_username = self.config.require("slurm_db_username")
        self.ServerInstanceType = self.config.require("ServerInstanceType")
        self.billing_code = self.config.require("billing_code")


def create_template(path: str) -> jinja2.Template:
    with open(path, 'r') as f:
        template = jinja2.Template(f.read())
    return template


def hash_file(path: str) -> pulumi.Output:
    with open(path, mode="r") as f:
        text = f.read()
    hash_str = hashlib.sha224(bytes(text, encoding='utf-8')).hexdigest()
    return pulumi.Output.concat(hash_str)


def get_password(
        name: str
):
    return RandomPassword(name,
                          length=16,
                          special=False,
                          min_lower=1,
                          min_numeric=1,
                          min_upper=1
                          ).result


def make_server(
        name: str,
        srvtype: str,
        tags: Dict,
        vpc_group_ids: List[str],
        subnet_id: str,
        instance_type: str,
        ami: str,
        key_name: str
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
        iam_instance_profile="WindowsJoinDomain",
        associate_public_ip_address=True,
        metadata_options={
            "http_put_response_hop_limit": 1,
            "http_tokens": "required",
        },
    )

    # Export final pulumi variables.
    pulumi.export(f'{type}_{name}_public_ip', server.public_ip)
    pulumi.export(f'{type}_{name}_public_dns', server.public_dns)

    return server


def main():
    config = ConfigValues()

    tags = {
        "rs:environment": "development",
        "rs:owner": config.email,
        "rs:project": "solutions",
        "rs:subsystem": config.billing_code
    }

    pulumi.export("billing_code", config.billing_code)

    # --------------------------------------------------------------------------
    # Print Pulumi stack name for better visibility
    # --------------------------------------------------------------------------

    stack_name = pulumi.get_stack()
    pulumi.export("stack_name", stack_name)

    # --------------------------------------------------------------------------
    # Pulumi secrets
    # --------------------------------------------------------------------------

    ad_password = get_password("ad_password")
    pulumi.export("ad_password", pulumi.Output.secret(ad_password))
    user_pass = get_password("user_pass")
    pulumi.export("user_pass", pulumi.Output.secret(user_pass))
    rsw_db_pass = get_password("rsw_db_pass")
    pulumi.export("rsw_db_pass", pulumi.Output.secret(rsw_db_pass))
    slurm_db_pass = get_password("slurm_db_pass")
    pulumi.export("slurm_db_pass", pulumi.Output.secret(slurm_db_pass))
    secure_cookie_key = RandomUuid("secure_cookie_key")
    pulumi.export("secure_cookie_key", pulumi.Output.secret(secure_cookie_key))

    # --------------------------------------------------------------------------
    # Set up keys.
    # --------------------------------------------------------------------------

    key_pair_name = f"{config.email}-keypair-for-pulumi"

    key_pair = ec2.get_key_pair(key_name=key_pair_name)

    pulumi.export("key_pair id", key_pair.key_name)

    # --------------------------------------------------------------------------
    # Set up S3 bucket to store scripts for parallelcluster
    # --------------------------------------------------------------------------

    s3bucket = s3.Bucket("hpc-scripts-" + stack_name,
                         acl="private",
                         force_destroy=True,
                         tags=tags | {
                             "AWS Parallelcluster Name": stack_name,
                             "Name": "hpc-scripts-" + stack_name,
                         })

    pulumi.export("s3_bucket_id", s3bucket.id)

    #################################################
    # VPC
    #################################################

    # Create a new VPC with 2 availability zones
    # Enable DNS support and hostnames for EFS mounting
    vpc = awsx.ec2.Vpc("pcluster-vpc", awsx.ec2.VpcArgs(
        number_of_availability_zones=2,
        enable_dns_hostnames=True,
        enable_dns_support=True,
        tags=tags | {
        "Name": f"vpc-{stack_name}"},
    ))

    # public_subnets = vpc.public_subnet_ids.apply(lambda ids: [ec2.get_subnet_output(id=id) for id in ids])
    # private_subnets = vpc.private_subnet_ids.apply(lambda ids: [ec2.get_subnet_output(id=id) for id in ids])
    # --------------------------------------------------------------------------
    # Get VPC information.
    # --------------------------------------------------------------------------
    # vpc = ec2.get_vpc(filters=[ec2.GetVpcFilterArgs(
    #     name="tag:Name",
    #     values=["shared"])])
    # vpc = ec2.get_vpc(filters=[ec2.GetVpcFilterArgs(
    #     name="vpc-id",
    #     values=["vpc-1486376d"])])
    # vpc_subnets = ec2.get_subnets(filters=[ec2.GetSubnetsFilterArgs(
    #     name="vpc-id",
    #     values=[vpc.id])])
    # vpc_subnet = ec2.get_subnet(id=vpc_subnets.ids[0])
    # vpc_subnet2 = ec2.get_subnet(id=vpc_subnets.ids[4])
    # pulumi.export("vpc_subnet", vpc_subnet.id)
    # pulumi.export("vpc_subnet2", vpc_subnet2.id)

    # --------------------------------------------------------------------------
    # ELB access from within AWS ParallelCluster
    # --------------------------------------------------------------------------

    policy = iam.Policy("elbaccess",
                        path="/",
                        description="ELB Access from head node of parallelcluster",
                        policy=json.dumps({
                            "Version": "2012-10-17",
                            "Statement": [{
                                "Action": [
                                    "elasticloadbalancing:DescribeTags",
                                    "elasticloadbalancing:DescribeTargetGroups",
                                    "elasticloadbalancing:DescribeLoadBalancers"
                                ],
                                "Effect": "Allow",
                                "Resource": "*",
                            }],
                        }))

    pulumi.export("elb_access", policy.arn)

    # --------------------------------------------------------------------------
    # Make security groups
    # --------------------------------------------------------------------------
    rsw_security_group = ec2.SecurityGroup(
        "WorkbenchServer",
        description="Security group for WorkbenchServer access",
        ingress=[
            {"protocol": "TCP", "from_port": 8787, "to_port": 8787,
             'cidr_blocks': [vpc.vpc.cidr_block], "description": "WorkbenchServer access"}
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("rsw_security_group", rsw_security_group.id)

    rsw_security_group_db = ec2.SecurityGroup(
        "postgres",
        description="Security group for PostgreSQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 5432, "to_port": 5432,
             'cidr_blocks': [vpc.vpc.cidr_block], "description": "PostgreSQL DB"}
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("rsw_security_group_db", rsw_security_group_db.id)

    slurm_security_group_db = ec2.SecurityGroup(
        "mysql",
        description="Security group for MySQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 3306, "to_port": 3306,
             'cidr_blocks': [vpc.vpc.cidr_block], "description": "MySQL DB"},
            {"protocol": "TCP", "from_port": 3306, "to_port": 3306,
             'cidr_blocks': [vpc.vpc.cidr_block], "description": "MySQL DB"},
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("slurm_security_group_db", slurm_security_group_db.id)

    security_group_ssh = ec2.SecurityGroup(
        "ssh",
        description="ssh access ",
        ingress=[
            {"protocol": "TCP", "from_port": 22, "to_port": 22,
             'cidr_blocks': ['0.0.0.0/0'], "description": "SSH"},
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbout traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("security_group_ssh", security_group_ssh.id)

    subnetgroup = rds.SubnetGroup("postgresdbsubnetgroup",
                                  subnet_ids=vpc.private_subnet_ids,
                                  tags={
                                      "Name": "Postgres subnet group",
                                  })

    rsw_db = rds.Instance(
        "rsw-db",
        instance_class="db.t3.micro",
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
        performance_insights_enabled=True
    )
    pulumi.export("rsw_db_port", rsw_db.port)
    pulumi.export("rsw_db_address", rsw_db.address)
    pulumi.export("rsw_db_endpoint", rsw_db.endpoint)
    pulumi.export("rsw_db_name", rsw_db.db_name)
    pulumi.export("rsw_db_user", config.rsw_db_username)

    slurm_db = rds.Instance(
        "slurm-db",
        instance_class="db.t3.medium",
        allocated_storage=5,
        backup_retention_period=7,
        username=config.slurm_db_username,
        password=slurm_db_pass,
        db_name="slurm",
        engine="mysql",
        publicly_accessible=False,
        skip_final_snapshot=True,
        tags=tags | {"Name": "slurm-db"},
        vpc_security_group_ids=[slurm_security_group_db.id],
        db_subnet_group_name=subnetgroup,
        performance_insights_enabled=True,
        performance_insights_retention_period=7,
        storage_encrypted=True
    )

    secret = secretsmanager.Secret(f"SlurmDBPassword-{stack_name}")

    example = secretsmanager.SecretVersion(f"SlurmDBPassword-{stack_name}",
                                           secret_id=secret.id,
                                           secret_string=slurm_db_pass)

    pulumi.export("slurm_db_pass_arn", example.arn)

    pulumi.export("slurm_db_port", slurm_db.port)
    pulumi.export("slurm_db_address", slurm_db.address)
    pulumi.export("slurm_db_endpoint", slurm_db.endpoint)
    pulumi.export("slurm_db_name", slurm_db.db_name)
    pulumi.export("slurm_db_user", config.slurm_db_username)

    secret = secretsmanager.Secret(f"SimpleADPassword-{stack_name}")

    example = secretsmanager.SecretVersion(f"SimpleADPassword-{stack_name}",
                                           secret_id=secret.id,
                                           secret_string=ad_password)

    pulumi.export("ad_password_arn", example.arn)


    secret = secretsmanager.Secret(f"PositUserPassword-{stack_name}")

    secretsmanager.SecretVersion(f"PositUserPassword-{stack_name}",
                                       secret_id=secret.id,
                                       secret_string=user_pass)

    pulumi.export("posit_user_pass", user_pass)


# --------------------------------------------------------------------------
    # Create Active Directory (SimpleAD)
    # --------------------------------------------------------------------------

    ad = directoryservice.Directory("pwb_directory",
                                    name=config.domain_name,
                                    password=ad_password,
                                    # edition="Standard",
                                    type="SimpleAD",
                                    size="Small",
                                    description="Directory for PWB environment",
                                    vpc_settings=directoryservice.DirectoryVpcSettingsArgs(
                                        vpc_id=vpc.vpc_id,
                                        subnet_ids=vpc.private_subnet_ids,
                                    ),
                                    tags=tags | {"Name": f"pwb-directory-{stack_name}"},
                                    )
    pulumi.export('ad_dns_1', ad.dns_ip_addresses[0])
    pulumi.export('ad_dns_2', ad.dns_ip_addresses[1])
    pulumi.export('ad_access_url', ad.access_url)

    jump_host = make_server(
        "jump_host",
        "ad",
        tags=tags | {"Name": f"jump-host-ad-{stack_name}"},
        vpc_group_ids=[security_group_ssh.id],
        instance_type=config.ServerInstanceType,
        subnet_id=vpc.public_subnet_ids.apply(lambda ids: ids[0]),
        ami=config.ami,
        key_name=key_pair.key_name
    )

    pulumi.export("vpc_public_subnet", vpc.public_subnet_ids.apply(lambda ids: ids[0]))

    pulumi.export("jump_host_dns", jump_host.public_dns)

    pulumi.export("ad_jump_host_public_ip", jump_host.public_dns)

    connection = remote.ConnectionArgs(
        host=jump_host.public_dns,  # host=jump_host.id,
        user="ubuntu",
        private_key=Path(f"{key_pair.key_name}.pem").read_text()
    )

    command_set_environment_variables = remote.Command(
        f"set-env",
        create=pulumi.Output.concat(
            'echo "export AD_PASSWD=', ad_password, '" >> .env;\n',
            'echo "export AD_DOMAIN=', config.domain_name, '" >> .env;\n',
        ),

        connection=connection,
        opts=pulumi.ResourceOptions(depends_on=jump_host)
    )

    command_install_justfile = remote.Command(
        f"install-justfile",
        create="\n".join([
            """curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/bin;""",
            """echo 'export PATH="$PATH:$HOME/bin"' >> ~/.bashrc;"""
        ]),
        opts=pulumi.ResourceOptions(depends_on=jump_host),
        connection=connection
    )

    command_copy_justfile = remote.CopyFile(
        f"copy-justfile",
        local_path="server-side-files/justfile",
        remote_path='justfile',
        connection=connection,
        opts=pulumi.ResourceOptions(depends_on=jump_host),
        triggers=[hash_file("server-side-files/justfile")]
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
                lambda x: create_template("server-side-files/config/krb5.conf").render(domain_name=config.domain_name))

        ),
        serverSideFile(
            "server-side-files/config/resolv.conf",
            "~/resolv.conf",
            pulumi.Output.all(config.domain_name, ad.dns_ip_addresses, config.aws_region).apply(
                lambda x: create_template("server-side-files/config/resolv.conf").render(domain_name=x[0], dns1=x[1][0],
                                                                                         dns2=x[1][1], aws_region=x[2]))
        ),
        serverSideFile(
            "server-side-files/config/create-users.exp",
            "~/create-users.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template("server-side-files/config/create-users.exp").render(domain_name=x[0],
                                                                                              ad_password=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/create-group.exp",
            "~/create-group.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template("server-side-files/config/create-group.exp").render(domain_name=x[0],
                                                                                              ad_password=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/add-group-member.exp",
            "~/add-group-member.exp",
            pulumi.Output.all(config.domain_name, ad_password).apply(
                lambda x: create_template("server-side-files/config/add-group-member.exp").render(domain_name=x[0],
                                                                                                  ad_password=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/useradd.sh",
            "~/useradd.sh",
            pulumi.Output.all(config.domain_name, ad_password, user_pass).apply(
                lambda x: create_template("server-side-files/config/useradd.sh").render(domain_name=x[0],
                                                                                        ad_password=x[1],
                                                                                        user_pass=x[2]))
        ),
    ]

    command_copy_config_files = []
    for f in server_side_files:
        if True:
            command_copy_config_files.append(
                remote.Command(
                    f"copy {f.file_out} server",
                    create=pulumi.Output.concat('echo "', f.template_render_command, f'" > {f.file_out}'),
                    connection=connection,
                    triggers=[hash_file(f.file_in)],
                    opts=pulumi.ResourceOptions(depends_on=jump_host)
                )
            )

    command_build_jumphost = remote.Command(
        f"build-jump-host",
        # create="alias just='/home/ubuntu/bin/just'; just build-rsw",
        create="""export PATH="$PATH:$HOME/bin"; just integrate-ad""",
        connection=connection,
        opts=pulumi.ResourceOptions(depends_on=[jump_host, command_set_environment_variables, command_install_justfile,
                                                command_copy_justfile] + command_copy_config_files)
    )


main()
