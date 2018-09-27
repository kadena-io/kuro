#!/bin/bash

## Set environment variables
echo "export AWS_ACCESS_KEY_ID=$1" >> ~/.bashrc
echo "export AWS_SECRET_ACCESS_KEY=$2" >> ~/.bashrc
echo "export EC2_INI_PATH=/etc/ansible/ec2.ini" >> ~/.bashrc
echo "export ANSIBLE_INVENTORY=/etc/ansible/ec2.py" >> ~/.bashrc
echo "export ANSIBLE_HOST_KEY_CHECKING=False" >> ~/.bashrc
