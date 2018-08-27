#!/bin/bash

## Set environment variables
export AWS_ACCESS_KEY_ID=$1
export AWS_SECRET_ACCESS_KEY=$2
export EC2_INI_PATH='/etc/ansible/ec2.ini'
export ANSIBLE_INVENTORY='/etc/ansible/ec2.py'
export ANSIBLE_HOST_KEY_CHECKING='False'
