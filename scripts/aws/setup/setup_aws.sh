#!/bin/sh

KEY_PAIR_PATH=./
SECURITY_GROUP_NAME=testenv-sg
KEY_PAIR_NAME=testenv-key

# Will need security credentials.
# i.e. AWS Access Key ID: AKIAIOSFODNN7EXAMPLE
#      AWS Security Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
#      Default region name: us-west-2
#      Default output format: json
aws configure &&


# Create security group that allows:
# a. The Ansible monitor instance to ssh into all instances it creates (required)
# b. All instances running kadenaserver to communicate via 10000 port (required)
# c. The Ansible monitor instance to be able to send API requests to kadenaserver instances
#    via HTTP, 8000 port (required)
# d. Allow developers to ssh into all instances created for debugging and 
#    monitoring (room for impovement)
# e. The Ansible playbooks to use the same security group name, 'testenv-sg', when 
#    creating instances (required)
echo "Creating Security Group" &&
aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "security group for testing kadena_beta" &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --protocol all --source-group $SECURITY_GROUP_NAME &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --protocol tcp --port 22 --cidr 0.0.0.0/0 &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,Ipv6Ranges=[{CidrIpv6=::/0}] &&
echo "Security Group $SECURITY_GROUP_NAME Created" &&


# Creates key pair, 'testenv-key', that Ansible will
# use when creating all instances (required). This allows Ansible
# to securely ssh into the intances.
# Save in secure location.
echo "Creating key pair $KEY_PAIR_NAME" &&
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > "$KEY_PAIR_PATH$KEY_PAIR_NAME".pem &&
chmod 400 "$KEY_PAIR_PATH$KEY_PAIR_NAME".pem &&
echo "Key pair created: $KEY_PAIR_PATH$KEY_PAIR_NAME.pem"
echo "Save key pair in secure and known location (i.e. ~/.ssh/)."
