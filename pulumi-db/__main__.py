"""An AWS Python Pulumi program"""

import hashlib
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

import jinja2
import pulumi
from pulumi_aws import ec2, efs, rds, lb, directoryservice
from pulumi_command import remote

def main():
    tags = {
        "rs:environment": "development",
        "rs:owner": "michael.mayer@posit.co",
        "rs:project": "solutions",
    }

# --------------------------------------------------------------------------
    # Get VPC information.
    # --------------------------------------------------------------------------
    
    
 
    # --------------------------------------------------------------------------
    # Make security groups
    # --------------------------------------------------------------------------

    security_group_db = ec2.SecurityGroup(
        "postgres",
        description="SLURM security group for PostgreSQL access",
        ingress=[
            {"protocol": "TCP", "from_port": 5432, "to_port": 5432, 
                'cidr_blocks': ['172.31.0.0/16'], "description": "PostgreSQL DB"},
	],
        egress=[
            {"protocol": "All", "from_port": 0, "to_port": 0, 
                'cidr_blocks': ['0.0.0.0/0'], "description": "Allow all outbout traffic"},
        ],
        tags=tags
    )




    db = rds.Instance(
        "ukhsa-rsw-db",
        instance_class="db.t3.micro",
        allocated_storage=5,
        username="rsw_db_admin",
        password="password",
        db_name="rsw",
        engine="postgres",
        publicly_accessible=True,
        skip_final_snapshot=True,
        tags=tags | {"Name": "rsw-db"},
	vpc_security_group_ids=[security_group_db.id]
    )
    pulumi.export("db_port", db.port)
    pulumi.export("db_address", db.address)
    pulumi.export("db_endpoint", db.endpoint)
    pulumi.export("db_name", db.name)


main()
