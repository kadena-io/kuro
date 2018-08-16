#!/bin/sh
DIR=${PWD}

## Sets up Ansible and Boto
sudo apt-get -y update
sudo apt-get -y install software-properties-common
sudo apt-add-repository -y ppa:ansible/ansible
sudo apt-get -y update
sudo apt-get -y install ansible

sudo apt-get -y install python-boto

## Downloads EC2 python scripts
cd /etc/ansible/
sudo wget 'https://raw.githubusercontent.com/ansible/ansible/devel/contrib/inventory/ec2.py'
sudo wget 'https://raw.githubusercontent.com/ansible/ansible/devel/contrib/inventory/ec2.ini'
sudo chmod +x ec2.py
cd $DIR

## Set environment variables
export AWS_ACCESS_KEY_ID=$1
export AWS_SECRET_ACCESS_KEY=$2
export EC2_INI_PATH='/etc/ansible/ec2.ini'
export ANSIBLE_INVENTORY='/etc/ansible/ec2.py'
