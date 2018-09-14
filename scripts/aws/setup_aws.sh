#!/bin/sh

KEY_PAIR_PATH=./
SECURITY_GROUP_NAME=testenv-sg
KEY_PAIR_NAME=testenv-key

# Configure AWS (will need security credentials)
aws configure &&

# Create security group
echo "Creating Security Group" &&
aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "security group for testing kadena_beta" &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --protocol all --source-group $SECURITY_GROUP_NAME &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --protocol tcp --port 22 --cidr 0.0.0.0/0 &&
aws ec2 authorize-security-group-ingress --group-name $SECURITY_GROUP_NAME --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,Ipv6Ranges=[{CidrIpv6=::/0}] &&
echo "Security Group $SECURITY_GROUP_NAME Created" &&

# Create key pair
# echo -n "Where should key pair be stored? (default: ./)"
# read answer
# TODO check that path ends in /

echo "Creating key pair $KEY_PAIR_NAME" &&
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > "$KEY_PAIR_PATH$KEY_PAIR_NAME".pem &&
chmod 400 "$KEY_PAIR_PATH$KEY_PAIR_NAME".pem &&
echo "Key pair created: $KEY_PAIR_PATH$KEY_PAIR_NAME.pem"
