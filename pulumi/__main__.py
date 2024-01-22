"""An AWS Python Pulumi program"""

import hashlib
import os
from time import time 
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

import random,string

import jinja2
import pulumi
import json
from pulumi_aws import ec2, efs, rds, lb, directoryservice, secretsmanager, iam
from pulumi_command import remote

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
        self.domain_password = self.config.require("domain_password")
        self.rsw_db_password = self.config.require("rsw_db_password")
        self.slurm_db_password = self.config.require("slurm_db_password")
        self.user_password = self.config.require("user_password")
        self.aws_region = self.config.require("region")
        self.rsw_db_username = self.config.require("rsw_db_username")
        self.slurm_db_username = self.config.require("slurm_db_username")
        self.secure_cookie_key = self.config.require("secure_cookie_key")
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
    # Stand up a server.
    server = ec2.Instance(
        f"{type}-{name}",
        instance_type=instance_type,
        vpc_security_group_ids=vpc_group_ids,
        ami=ami,
        tags=tags,
        subnet_id=subnet_id,
        key_name=key_name,
        iam_instance_profile="WindowsJoinDomain",
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

    timestamp = int(time())

    key_pair_name = f"{config.email}-keypair-for-pulumi"
    
    key_pair = ec2.get_key_pair(key_name=key_pair_name)

    pulumi.export("key_pair id", key_pair.key_name)

    # --------------------------------------------------------------------------
    # Get VPC information.
    # --------------------------------------------------------------------------
    vpc = ec2.get_vpc(filters=[ec2.GetVpcFilterArgs(
        name="tag:Name",
        values=["shared"])])
    vpc = ec2.get_vpc(filters=[ec2.GetVpcFilterArgs(
        name="vpc-id",
        values=["vpc-1486376d"])])
    vpc_subnets = ec2.get_subnets(filters=[ec2.GetSubnetsFilterArgs(
        name="vpc-id",
        values=[vpc.id])])
    vpc_subnet = ec2.get_subnet(id=vpc_subnets.ids[0])
    vpc_subnet2 = ec2.get_subnet(id=vpc_subnets.ids[4]) 
    pulumi.export("vpc_subnet", vpc_subnet.id)
    pulumi.export("vpc_subnet2", vpc_subnet2.id)

 
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

    rsw_security_group_db = ec2.SecurityGroup(
        "postgres",
        description="Security group for PostgreSQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 5432, "to_port": 5432, 
                'cidr_blocks': [vpc_subnet.cidr_block], "description": "PostgreSQL DB"},
	    {"protocol": "TCP", "from_port": 5432, "to_port": 5432,
                'cidr_blocks': [vpc_subnet2.cidr_block], "description": "PostgreSQL DB"},
	],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0, 
                'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.id
    )
    pulumi.export("rsw_security_group_db", rsw_security_group_db.id)

    slurm_security_group_db = ec2.SecurityGroup(
        "mysql",
        description="Security group for MySQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 3306, "to_port": 3306, 
                'cidr_blocks': [vpc_subnet.cidr_block], "description": "MySQL DB"},
	    {"protocol": "TCP", "from_port": 3306, "to_port": 3306,
                'cidr_blocks': [vpc_subnet2.cidr_block], "description": "MySQL DB"},
	],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0, 
                'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.id
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
        vpc_id=vpc.id
    )
    pulumi.export("security_group_ssh", security_group_ssh.id)

    subnetgroup = rds.SubnetGroup("postgresdbsubnetgroup",
        subnet_ids=[
            vpc_subnet.id,
            vpc_subnet2.id,
        ],
        tags={
            "Name": "Postgres subnet group",
        })
    
    rsw_db = rds.Instance(
        "rsw-db",
        instance_class="db.t3.micro",
        allocated_storage=5,
        username=config.rsw_db_username,
        password=config.rsw_db_password,
        db_name="pwb",
        engine="postgres",
        publicly_accessible=True,
        skip_final_snapshot=True,
        tags=tags | {"Name": "pwb-db"},
	    vpc_security_group_ids=[rsw_security_group_db.id],
        db_subnet_group_name=subnetgroup 
    )
    pulumi.export("rsw_db_port", rsw_db.port)
    pulumi.export("rsw_db_address", rsw_db.address)
    pulumi.export("rsw_db_endpoint", rsw_db.endpoint)
    pulumi.export("rsw_db_name", rsw_db.db_name)
    pulumi.export("rsw_db_user", config.rsw_db_username)
    pulumi.export("rsw_db_pass", config.rsw_db_password)

    slurm_db = rds.Instance(
        "slurm-db",
        instance_class="db.t3.micro",
        allocated_storage=5,
        username=config.slurm_db_username,
        password=config.slurm_db_password,
        db_name="slurm",
        engine="mysql",
        publicly_accessible=True,
        skip_final_snapshot=True,
        tags=tags | {"Name": "slurm-db"},
	    vpc_security_group_ids=[slurm_security_group_db.id],
        db_subnet_group_name=subnetgroup 
    )

    secret = secretsmanager.Secret("SlurmDBPassword")

    example = secretsmanager.SecretVersion("SlurmDBPassword",
        secret_id=secret.id,
        secret_string=config.slurm_db_password)
    
    pulumi.export("slurm_db_pass_arn", example.arn)

    pulumi.export("slurm_db_port", slurm_db.port)
    pulumi.export("slurm_db_address", slurm_db.address)
    pulumi.export("slurm_db_endpoint", slurm_db.endpoint)
    pulumi.export("slurm_db_name", slurm_db.db_name)
    pulumi.export("slurm_db_user", config.slurm_db_username)
    pulumi.export("slurm_db_pass", config.slurm_db_password)



    secret = secretsmanager.Secret("SimpleADPassword")

    example = secretsmanager.SecretVersion("SimpleADPassword",
        secret_id=secret.id,
        secret_string=config.domain_password)
    
    pulumi.export("domain_password_arn", example.arn)
    pulumi.export("domain_password", config.domain_password)

    
  


    # --------------------------------------------------------------------------
    # Create Active Directory (SimpleAD)
    # --------------------------------------------------------------------------

    ad = directoryservice.Directory("pwb_directory",
        name=config.domain_name,
        password=config.domain_password,
        #edition="Standard",
        type="SimpleAD",
        size="Small",
        description="Directory for PWB environment",
        vpc_settings=directoryservice.DirectoryVpcSettingsArgs(
            vpc_id=vpc.id,
            subnet_ids=[
                vpc_subnet.id,
                vpc_subnet2.id,
            ],
        ),
        tags=tags | {"Name": "pwb-directory"},
    )
    pulumi.export('ad_dns_1', ad.dns_ip_addresses[0])
    pulumi.export('ad_dns_2', ad.dns_ip_addresses[1])
    pulumi.export('ad_access_url', ad.access_url) 
    pulumi.export('ad_password',config.domain_password) 

    jump_host=make_server(
            "jump_host", 
            "ad",
            tags=tags | {"Name": "jump-host-ad"},
            vpc_group_ids=[security_group_ssh.id],
            instance_type=config.ServerInstanceType,
            subnet_id=vpc_subnet.id,
            ami=config.ami,
            key_name=key_pair.key_name
        )
    
    pulumi.export("jump_host_dns", jump_host.public_dns)
    
    connection = remote.ConnectionArgs(
            host=jump_host.public_dns ,# host=jump_host.id, 
            user="ubuntu", 
            private_key=Path(f"{key_pair.key_name}.pem").read_text()
        )
    
    command_set_environment_variables = remote.Command(
            f"set-env", 
            create=pulumi.Output.concat(
                'echo "export AD_PASSWD=',         config.domain_password,   '" >> .env;\n',
                'echo "export AD_DOMAIN=',         config.domain_name,   '" >> .env;\n',
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
                pulumi.Output.all().apply(lambda x: create_template("server-side-files/config/krb5.conf").render(domain_name=config.domain_name))
    
            ),
            serverSideFile(
                "server-side-files/config/resolv.conf",
                "~/resolv.conf",
                pulumi.Output.all(config.domain_name,ad.dns_ip_addresses,config.aws_region).apply(lambda x: create_template("server-side-files/config/resolv.conf").render(domain_name=x[0],dns1=x[1][0], dns2=x[1][1], aws_region=x[2]))
            ),
            serverSideFile(
                "server-side-files/config/create-users.exp",
                "~/create-users.exp",
                pulumi.Output.all(config.domain_name,config.domain_password).apply(lambda x: create_template("server-side-files/config/create-users.exp").render(domain_name=x[0],domain_passwd=x[1]))
            ),
            serverSideFile(
                "server-side-files/config/create-group.exp",
                "~/create-group.exp",
                pulumi.Output.all(config.domain_name,config.domain_password).apply(lambda x: create_template("server-side-files/config/create-group.exp").render(domain_name=x[0],domain_passwd=x[1]))
            ),
            serverSideFile(
                "server-side-files/config/add-group-member.exp",
                "~/add-group-member.exp",
                pulumi.Output.all(config.domain_name,config.domain_password).apply(lambda x: create_template("server-side-files/config/add-group-member.exp").render(domain_name=x[0],domain_passwd=x[1]))
            ),
            serverSideFile(
                "server-side-files/config/useradd.sh",
                "~/useradd.sh",
                pulumi.Output.all(config.domain_name,config.domain_password,config.user_password).apply(lambda x: create_template("server-side-files/config/useradd.sh").render(domain_name=x[0],domain_passwd=x[1],user_password=x[2]))
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
            opts=pulumi.ResourceOptions(depends_on=[jump_host, command_set_environment_variables, command_install_justfile, command_copy_justfile] + command_copy_config_files)
    )


main()
