"""An AWS Python Pulumi program"""

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List


import jinja2
import pulumi
import json
from pulumi_aws import ec2, rds, directoryservice, secretsmanager, iam, s3, Provider, get_region, lb
import pulumi_awsx as awsx
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
    public_key: str = field(init=False)
    billing_code: str = field(init=False)
    my_ip: str = field(init=False)

    def __post_init__(self):
        self.email = self.config.require("email")
        self.domain_name = self.config.require("domain_name")
        self.aws_region = self.config.require("region")
        self.rsw_db_username = self.config.require("rsw_db_username")
        self.slurm_db_username = self.config.require("slurm_db_username")
        self.ServerInstanceType = self.config.require("ServerInstanceType")
        self.billing_code = self.config.require("billing_code")
        self.my_ip = self.config.require("my_ip")


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

    

    posit_user_pass = get_password("posit_user_pass")
    pulumi.export("posit_user_pass", pulumi.Output.secret(posit_user_pass))
    posit_user_pass_secret = secretsmanager.Secret(f"PositUserPassword-{stack_name}")
    secretsmanager.SecretVersion(f"PositUserPassword-{stack_name}",
                                       secret_id=posit_user_pass_secret.id,
                                       secret_string=posit_user_pass)

    pulumi.export("posit_user_pass_arn", posit_user_pass_secret.arn)
    
    


    secure_cookie_key = RandomUuid("secure_cookie_key")
    pulumi.export("secure_cookie_key", pulumi.Output.secret(secure_cookie_key.id))

    # --------------------------------------------------------------------------
    # Set up keys.
    # --------------------------------------------------------------------------

    key_pair_name = f"{config.email}-keypair-for-pulumi-{stack_name}"


    ssh_key = PrivateKey(key_pair_name,
        algorithm="ED25519"
    )   

    # Export the public key in OpenSSH format
    pulumi.export("public_key_ssh", ssh_key.public_key_openssh)

    # Optionally, export the private key (be cautious with this)
    pulumi.export("private_key_ssh", pulumi.Output.secret(ssh_key.private_key_openssh))

    key_pair = ec2.KeyPair("pcluster-deployment",
        key_name=key_pair_name,
        public_key=ssh_key.public_key_openssh
    )

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
    vpc = awsx.ec2.Vpc(f"pcluster-vpc-{stack_name}", awsx.ec2.VpcArgs(
        number_of_availability_zones=2,
        enable_dns_hostnames=True,
        enable_dns_support=True,
        tags=tags | {
        "Name": f"vpc-{stack_name}"},
    ))

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
                                    "elasticloadbalancing:DescribeLoadBalancers",
                                    "elasticloadbalancing:DescribeTargetHealth",
                                ],
                                "Effect": "Allow",
                                "Resource": "*",
                            }],
                        }))

    pulumi.export("iam_elb_access", policy.arn)

    # --------------------------------------------------------------------------
    # S3 access from login nodes
    # --------------------------------------------------------------------------

    policy = iam.Policy("s3access",
                        path="/",
                        description="S3 Access from login nodes of parallelcluster",
                        policy=json.dumps({
                            "Version": "2012-10-17",
                            "Statement": [{
                                "Action": [
                                    "s3:Get*",
                                    "s3:List*",
                                    "s3:Describe*",
                                    "s3-object-lambda:Get*",
                                    "s3-object-lambda:List*"
                                ],
                                "Effect": "Allow",
                                "Resource": "*",
                            }],
                        }))

    pulumi.export("iam_s3_access", policy.arn)
    

    # --------------------------------------------------------------------------
    # Make security group for Posit Workbench
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


    # --------------------------------------------------------------------------
    # Posit Workbench DB (PostgreSQL)
    # --------------------------------------------------------------------------

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

    subnetgroup = rds.SubnetGroup("postgresdbsubnetgroup",
                                  subnet_ids=vpc.private_subnet_ids,
                                  tags={
                                      "Name": "Postgres subnet group",
                                  })

    rsw_db_pass = get_password("rsw_db_pass")
    pulumi.export("rsw_db_pass", pulumi.Output.secret(rsw_db_pass))

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


    # --------------------------------------------------------------------------
    # SLURM Accounting DB (MySQL)
    # --------------------------------------------------------------------------

    slurm_security_group_db = ec2.SecurityGroup(
        "mysql",
        description="Security group for MySQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 3306, "to_port": 3306,
             'cidr_blocks': [vpc.vpc.cidr_block], "description": "MySQL DB"}
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbound traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("slurm_security_group_db", slurm_security_group_db.id)

    slurm_db_pass = get_password("slurm_db_pass")
    pulumi.export("slurm_db_pass", pulumi.Output.secret(slurm_db_pass))

    secret = secretsmanager.Secret(f"SlurmDBPassword-{stack_name}")
    slurm_db_pass_sec = secretsmanager.SecretVersion(f"SlurmDBPassword-{stack_name}",
                                           secret_id=secret.id,
                                           secret_string=slurm_db_pass)
    pulumi.export("slurm_db_pass_arn", slurm_db_pass_sec.arn)

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
    ad_password_sec = secretsmanager.SecretVersion(f"SimpleADPassword-{stack_name}",
                                           secret_id=secret.id,
                                           secret_string=ad_password)
    pulumi.export("ad_password_arn", ad_password_sec.arn)

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

    # --------------------------------------------------------------------------
    # Jump Host (AD)
    # --------------------------------------------------------------------------

    ssh_security_group = ec2.SecurityGroup(
        "ssh",
        description="ssh access ",
        ingress=[
            {"protocol": "TCP", "from_port": 22, "to_port": 22,
             'cidr_blocks': [f"{config.my_ip}/32"], "description": "SSH"},
        ],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0,
             'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbout traffic"},
        ],
        tags=tags,
        vpc_id=vpc.vpc_id
    )
    pulumi.export("ssh_security_group", ssh_security_group.id)

    # Fetch the most recent Ubuntu 20.04 AMI with HVM and x86_64 architecture in the specified region
    ami = ec2.get_ami(most_recent=True,
                        owners=["099720109477"],  # Canonical
                        filters=[
                            {"name": "name", "values": ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]},
                            {"name": "architecture", "values": ["x86_64"]},
                            {"name": "virtualization-type", "values": ["hvm"]},
                        ],
                        opts=pulumi.InvokeOptions(provider=Provider("test",region=get_region().name)))

    # Export the AMI ID
    pulumi.export("ami_id", ami.id)

    jump_host = make_server(
        "jump_host",
        "ad",
        tags=tags | {"Name": f"jump-host-ad-{stack_name}"},
        vpc_group_ids=[ssh_security_group.id],
        instance_type=config.ServerInstanceType,
        subnet_id=vpc.public_subnet_ids.apply(lambda ids: ids[0]),
        ami=ami.id,
        key_name=key_pair.key_name
    )

    pulumi.export("vpc_public_subnet", vpc.public_subnet_ids.apply(lambda ids: ids[0]))
    pulumi.export("vpc_private_subnet", vpc.private_subnet_ids.apply(lambda ids: ids[0]))
    pulumi.export("jump_host_dns", jump_host.public_dns)
    pulumi.export("jump_host_public_ip", jump_host.public_ip)
    pulumi.export("jump_host_instance_id", jump_host.id)

    connection = remote.ConnectionArgs(
        host=jump_host.public_dns,  # host=jump_host.id,
        user="ubuntu",
        #private_key=Path(f"{key_pair.key_name}.pem").read_text()
        private_key=ssh_key.private_key_openssh
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
            pulumi.Output.all(config.domain_name, ad_password, posit_user_pass).apply(
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

    #########################################################################
    # Section: Public Load Balancer
    # Date: 2024-12-13
    #########################################################################


    lb_security_group = ec2.SecurityGroup(
        "ha-lb-secgrp",
        vpc_id=vpc.vpc_id,
        ingress=[
            # Allow all 80/443 incoming
            ec2.SecurityGroupIngressArgs(
                from_port=80,
                to_port=80,
                protocol="tcp",
                cidr_blocks=["0.0.0.0/0"],
            )
        ],
        egress=[
            # Allow outbound traffic to private subnet HTTP only
            ec2.SecurityGroupEgressArgs(
                from_port=80,
                to_port=80,
                protocol="tcp",
                cidr_blocks=[vpc.vpc.cidr_block]
            )
        ],
        tags=tags,
    )

    public_lb = lb.LoadBalancer(
        "ha-lb",
        load_balancer_type="network",
        security_groups=[lb_security_group.id],
        subnets=vpc.public_subnet_ids,
        tags=tags ,
    )

    lb_target_group = lb.TargetGroup(
        "ha-lb-target-group",
        port=80,
        protocol="HTTP",
        stickiness=lb.TargetGroupStickinessArgs(
            type="lb_cookie",
            cookie_duration=604800, # Max duration: 1 week
        ),
        vpc_id=vpc.vpc_id,
        tags=tags,
    )

    lb_listener = lb.Listener(
        "ha-lb-listener",
        load_balancer_arn=public_lb.arn,
        port=80,
        protocol="HTTP",
        default_actions=[lb.ListenerDefaultActionArgs(
            type="forward",
            target_group_arn=lb_target_group.arn,
        )],
        tags=tags,
    )

main()
