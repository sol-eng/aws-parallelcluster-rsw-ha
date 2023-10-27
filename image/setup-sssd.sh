#!/Bin/bash

# Setup LDAP auth 

aws s3 cp s3://hpc-scripts1234/sssd.conf /etc/sssd 
chmod 0600 /etc/sssd/sssd.conf 

systemctl stop sssd && rm -rf /var/log/sssd/* /var/lib/sss/db/* && systemctl start sssd
