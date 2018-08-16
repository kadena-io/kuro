# Ansible and AWS

## Setup 
Download ansible and boto in all servers.
For Ubuntu: 
<https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#latest-releases-via-apt-ubuntu>
`sudo apt-get install python-boto`

Download [ec2.py](https://raw.githubusercontent.com/ansible/ansible/devel/contrib/inventory/ec2.py)
and [ec2.ini](https://raw.githubusercontent.com/ansible/ansible/devel/contrib/inventory/ec2.ini) and save both in /etc/ansible/.

## Other
Use ssh-agent to transfer ssh permissions. 

To get ssh agent working, had to run `ssh -v < intance public DNS >`

To access servers tagged by Name:
`ansible -m ping tag_Name_kadena_server`

Environment setup:
export AWS_ACCESS_KEY_ID='ABCD'
export AWS_SECRET_ACCESS_KEY='123'

export EC2_INI_PATH=/etc/ansible/ec2.ini
export ANSIBLE_INVENTORY=/etc/ansible/ec2.py

To terminate instance from terminal:
ansible localhost -m ec2 -a "state=absent region=us-west-2 instance_ids=example_id"
A more dynamic approach to spin up and terminate instances will require playbooks 
and more robust use of ec2 module. See examples [here](https://docs.ansible.com/ansible/2.6/modules/ec2_module.html).
