"""An AWS Python Pulumi program"""

import hashlib
import os
from time import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

import random, string

import jinja2
import pulumi
from pulumi_aws import ec2, efs, rds, lb, directoryservice, secretsmanager
from pulumi_command import local
from textwrap import dedent
import pulumiverse_time as time
from rstudio_pulumi.aws.vpc import Vpc, Privacy
from rstudio_pulumi.utils.networking import Network
from rstudio_pulumi.utils.networking import EqualSizeSubnetStrategy


# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

@dataclass
class ConfigValues:
    """A single object to manage all config files."""
    config: pulumi.Config = field(default_factory=lambda: pulumi.Config())
    email: str = field(init=False)
    public_key: str = field(init=False)
    interpreter: str = field(init=False)
    billing_code: str = field(init=False)


    def __post_init__(self):
        self.email = self.config.require("email")
        self.ami = self.config.require("ami")
        self.domain_name = self.config.require("domain_name")
        self.domain_password = self.config.require("domain_password")
        self.db_password = self.config.require("db_password")
        self.user_password = self.config.require("user_password")
        self.aws_region = self.config.require("region")
        self.db_username = self.config.require("db_username")
        self.secure_cookie_key = self.config.require("secure_cookie_key")
        self.ServerInstanceType = self.config.require("ServerInstanceType")
        self.interpreter = self.config.require("interpreter")
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


def make_server(
        name: str,
        type: str,
        tags: Dict,
        vpc_group_ids: List[str],
        subnet_id: str,
        instance_type: str,
        ami: str,
        key_name: str
):
    user_data = dedent(f"""
    #!/bin/bash
    echo "Installing commonly used Linux tools"
    sudo apt-get update
    sudo apt-get upgrade -y
    cd /tmp
    sudo apt install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
    sudo systemctl enable amazon-ssm-agent
    sudo systemctl start amazon-ssm-agent
    echo 'export PATH=$PATH:$HOME/bin' >> ~/.bashrc;
    """).strip()

    # Stand up a server.
    server = ec2.Instance(
        f"{type}-{name}",
        instance_type=instance_type,
        vpc_security_group_ids=vpc_group_ids,
        ami=ami,
        tags=tags,
        subnet_id=subnet_id,
        key_name=key_name,
        user_data=user_data,
        iam_instance_profile="WindowsJoinDomain",
        metadata_options=ec2.LaunchTemplateMetadataOptionsArgs(
            http_endpoint="enabled",
            http_tokens="required",
        ),
        associate_public_ip_address=True
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

    path_to_bash = config.interpreter

    interpreter = [path_to_bash, "-c"]

    # --------------------------------------------------------------------------
    # Print Pulumi stack name for better visibility
    # --------------------------------------------------------------------------

    pulumistack = pulumi.get_stack()
    pulumi.export("Pulumi Stack NAME", pulumistack)
    pulumi.export("user_password", config.user_password)
    pulumi.export("secure_cookie_key", config.secure_cookie_key)
    # --------------------------------------------------------------------------
    # Set up keys.
    # --------------------------------------------------------------------------

    key_pair_name = f"{config.email}-keypair-for-pulumi"

    key_pair = ec2.get_key_pair(key_name=key_pair_name)

    pulumi.export("key_pair id", key_pair.key_name)

    # --------------------------------------------------------------------------
    # Get VPC information.
    # --------------------------------------------------------------------------

    azs = ['euw1-az1', 'euw1-az2']
    cidr = Network('172.19.64.0/18', azs, EqualSizeSubnetStrategy())
    cidr_str = cidr.cidr.with_prefixlen
    benchmarking_vpc = Vpc(
        name='slurm-benchmarking',
        cidr_block=cidr,
        azs=azs,
        tags=tags,
        opts=pulumi.ResourceOptions()
    )
    private_subnets = benchmarking_vpc.subnets[Privacy.PRIVATE]
    benchmarking_vpc.with_nat_gateways() \
        .with_nacl_rule(port_range=443, cidr_blocks=['0.0.0.0/0']) \
        .with_nacl_rule(port_range=80, cidr_blocks=['0.0.0.0/0']) \
        .with_nacl_rule(egress=True, port_range=0, protocol=-1, cidr_blocks=['0.0.0.0/0']) \
        .with_nacl_rule(egress=True, port_range=0, protocol=-1, cidr_blocks=['0.0.0.0/0'], privacy=Privacy.PRIVATE) \
        .with_nacl_rule(port_range=53, protocol=-1, cidr_blocks=['0.0.0.0/0']) \
        .with_nacl_rule(port_range=53, protocol=-1, cidr_blocks=['0.0.0.0/0'], privacy=Privacy.PRIVATE) \
        .with_nacl_rule(port_range=2049, protocol=-1, cidr_blocks=['0.0.0.0/0'], privacy=Privacy.PRIVATE) \ #TODO: replace with vpc range
        .with_nacl_rule(port_range=111, protocol=-1, cidr_blocks=['0.0.0.0/0'], privacy=Privacy.PRIVATE) \
        .with_nacl_rule(port_range=988, protocol=-1, cidr_blocks=['0.0.0.0/0'], privacy=Privacy.PRIVATE)

    benchmarking_vpc.with_endpoint(service='ec2')
    benchmarking_vpc.with_endpoint(service='kms')
    benchmarking_vpc.with_endpoint(service="ec2messages")
    benchmarking_vpc.with_endpoint(service="s3")
    benchmarking_vpc.with_endpoint(service="ssm")
    benchmarking_vpc.with_endpoint(service="ssmmessages")

    vpc_subnet_0 = [x for x in benchmarking_vpc.subnets[Privacy.PRIVATE]][0]
    vpc_subnet_1 = [x for x in benchmarking_vpc.subnets[Privacy.PRIVATE]][1]

    pulumi.export("vpc_subnet_0", vpc_subnet_0.id)
    pulumi.export("vpc_subnet_1", vpc_subnet_1.id)

    # --------------------------------------------------------------------------
    # Make security groups
    # --------------------------------------------------------------------------

    security_group_db = ec2.SecurityGroup(
        "postgres",
        description="SLURM security group for PostgreSQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 5432, "to_port": 5432,
             'cidr_blocks': [vpc_subnet_0.cidr_block], "description": "PostgreSQL DB"},
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=benchmarking_vpc.vpc.id
    )
    pulumi.export("security_group_db", security_group_db.id)

    default_security_group = ec2.SecurityGroup(
        "default ssh security group",
        description="default ssh security group",
        ingress=[
            {"protocol": "TCP", "from_port": 22, "to_port": 22,
             'cidr_blocks': [vpc_subnet_0.cidr_block], "description": "SSH"},
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbout traffic"},
        ],
        tags=tags,
        vpc_id=benchmarking_vpc.vpc.id,
        opts=pulumi.ResourceOptions(depends_on=[benchmarking_vpc])
    )
    pulumi.export("default_security_group", default_security_group.id)

    subnetgroup = rds.SubnetGroup("postgresdbsubnetgroup",
                                  subnet_ids=[
                                      vpc_subnet_0.id,
                                      vpc_subnet_1.id,
                                  ],
                                  tags={
                                      "Name": "Postgres subnet group",
                                  })

    db = rds.Instance(
        "rsw-db",
        instance_class="db.t3.micro",
        allocated_storage=5,
        username=config.db_username,
        password=config.db_password,
        db_name="pwb",
        engine="postgres",
        publicly_accessible=True,
        skip_final_snapshot=True,
        tags=tags | {"Name": "pwb-db"},
        vpc_security_group_ids=[security_group_db.id],
        db_subnet_group_name=subnetgroup
    )
    pulumi.export("db_port", db.port)
    pulumi.export("db_address", db.address)
    pulumi.export("db_endpoint", db.endpoint)
    pulumi.export("db_name", db.name)
    pulumi.export("db_user", config.db_username)
    pulumi.export("db_pass", config.db_password)

    secret = secretsmanager.Secret("SimpleADPassword")

    example = secretsmanager.SecretVersion("SimpleADPassword",
                                           secret_id=secret.id,
                                           secret_string=config.domain_password)

    pulumi.export("domain_password_arn", example.arn)
    pulumi.export("domain_password", config.domain_password)

    # --------------------------------------------------------------------------
    # Create Active Directory (SimpleAD)
    # --------------------------------------------------------------------------

    ad = directoryservice.Directory(f"pwb_directory_{config.email}",
                                    name=config.domain_name,
                                    password=config.domain_password,
                                    # edition="Standard",
                                    type="SimpleAD",
                                    size="Small",
                                    description="Directory for PWB environment created by " + config.email,
                                    vpc_settings=directoryservice.DirectoryVpcSettingsArgs(
                                        vpc_id=benchmarking_vpc.vpc.id,
                                        subnet_ids=[
                                            vpc_subnet_0.id,
                                            vpc_subnet_1.id,
                                        ],
                                    ),
                                    tags=tags | {"Name": "pwb-directory"},
                                    )
    pulumi.export('ad_dns_1', ad.dns_ip_addresses[0])
    pulumi.export('ad_dns_2', ad.dns_ip_addresses[1])
    pulumi.export('ad_access_url', ad.access_url)
    pulumi.export('ad_password', config.domain_password)

    jump_host = make_server(
        "jump_host",
        "ad",
        tags=tags | {"Name": "jump-host-ad"},
        vpc_group_ids=[default_security_group.id],
        instance_type=config.ServerInstanceType,
        subnet_id=vpc_subnet_0.id,
        ami=config.ami,
        key_name=key_pair.key_name
    )

    pulumi.export("jump_host_id", jump_host.id)
    server_wait = time.Sleep("wait_for_server", create_duration="30s",
                             opts=pulumi.ResourceOptions(depends_on=[jump_host]))

    pulumi.export("jump_host_dns", jump_host.public_dns)

    ssh_wrapper = jump_host.id.apply(
        lambda x: f"ssh ubuntu@{x} -i ./\"sam.cofer@posit.co-keypair-for-pulumi.pem\" -F ./config ")

    rsw_env = dedent(f"""
            << EOF 
            echo "export AD_PASSWD={config.domain_password}" >> .env;
            echo "export AD_DOMAIN={config.domain_name}" >> .env;
            EOF
            """).strip()

    command_set_environment_variables = local.Command(
        f"set-env",
        create=pulumi.Output.concat(ssh_wrapper, rsw_env),
        interpreter=interpreter,
        opts=pulumi.ResourceOptions(depends_on=[server_wait])
    )

    install_justfile = dedent(f"""
            << EOF 
            echo 'test'
            curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/bin;
            EOF
            """).strip()

    command_install_justfile = local.Command(
        f"server-install-justfile",
        create=pulumi.Output.concat(ssh_wrapper, install_justfile),
        interpreter=interpreter,
        opts=pulumi.ResourceOptions(depends_on=[server_wait])
    )

    copy_justfile = jump_host.id.apply(
        lambda x: f"scp -i ./{key_pair_name}.pem -F ./config server-side-files/justfile ubuntu@{x}:~/justfile")

    command_copy_justfile = local.Command(
        f"server-copy-justfile",
        create=copy_justfile,
        interpreter=interpreter,
        opts=pulumi.ResourceOptions(depends_on=[server_wait])
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
            pulumi.Output.all(config.domain_name, config.domain_password).apply(
                lambda x: create_template("server-side-files/config/create-users.exp").render(domain_name=x[0],
                                                                                              domain_passwd=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/create-group.exp",
            "~/create-group.exp",
            pulumi.Output.all(config.domain_name, config.domain_password).apply(
                lambda x: create_template("server-side-files/config/create-group.exp").render(domain_name=x[0],
                                                                                              domain_passwd=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/add-group-member.exp",
            "~/add-group-member.exp",
            pulumi.Output.all(config.domain_name, config.domain_password).apply(
                lambda x: create_template("server-side-files/config/add-group-member.exp").render(domain_name=x[0],
                                                                                                  domain_passwd=x[1]))
        ),
        serverSideFile(
            "server-side-files/config/useradd.sh",
            "~/useradd.sh",
            pulumi.Output.all(config.domain_name, config.domain_password, config.user_password).apply(
                lambda x: create_template("server-side-files/config/useradd.sh").render(domain_name=x[0],
                                                                                        domain_passwd=x[1],
                                                                                        user_password=x[2]))
        ),
    ]

    command_copy_config_files = []
    for f in server_side_files:
        if True:
            command_copy_config_files.append(
                local.Command(
                    f"copy {f.file_out} to server",
                    create=pulumi.Output.concat(ssh_wrapper, "<<-EOF\n", f"cat <<-EOE > {f.file_out}\n",
                                                f.template_render_command, "\nEOE", "\nEOF"),
                    interpreter=interpreter,
                    opts=pulumi.ResourceOptions(depends_on=[server_wait])
                )
            )

    build_jumphost = pulumi.Output.all(jump_host.public_ip).apply(
        lambda x:
        dedent(f"""
            << EOF
            just integrate-ad
            EOF
            """).strip())

    build_wait = time.Sleep(f"wait_for_justfile", create_duration="20s",
                            opts=pulumi.ResourceOptions(depends_on=[command_copy_justfile, command_install_justfile]))

    command_integrate_ad = local.Command(
        f"integrate ad",
        create=pulumi.Output.concat(ssh_wrapper, build_jumphost),
        interpreter=interpreter,
        opts=pulumi.ResourceOptions(
            depends_on=[command_copy_justfile, command_install_justfile, server_wait,
                        # ad,
                        build_wait,
                        command_set_environment_variables])
    )


main()
