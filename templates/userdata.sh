#!/bin/bash

function error_exit
{
 cfn-signal -e 1 --stack kafka-setup2-BrokerStack-NA48RQ61P3GO --region us-east-1 --resource Nodes
 exit 1
}

PATH=$PATH:/usr/local/bin 

##Yum and Apt repo update
[ `which yum` ] && yum install -y epel-release 
[ `which apt-get` ] && apt-get -y update 
## Install core O/S packages
if [ ! -f /usr/bin/sshpass ] ; then 
  [ `which yum` ] && yum install -y sshpass 
  [ `which apt-get` ] && apt-get -y install sshpass 
fi 

which pip &> /dev/null 
if [ $? -ne 0 ] ; then 
  [ `which yum` ] && yum install -y python-pip
  [ `which apt-get` ] && apt-get -y install python-pip
fi 
python -m pip install --upgrade pip
python -m pip install awscli --ignore-installed six

## Install and Update CloudFormation
easy_install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

## Signal that the node is up
cfn-signal -e 0 --stack kafka-setup2-BrokerStack-NA48RQ61P3GO --region us-east-1 --resource Nodes

## Save off other cluster details in prep for configuration
echo awsqs > /tmp/clustername
echo Confluent Open Source > /tmp/cedition
echo Disabled > /tmp/csecurity
[ "Disabled" = 'Disabled' ] && rm /tmp/csecurity
echo 5.0.0 > /tmp/cversion

## Retrieve scripts to deploy Confluent on the instances 
##  cfn-init downloads everything 
##  and then we're off to the races 
cfn-init -v          --stack kafka-setup2-BrokerStack-NA48RQ61P3GO         --resource NodeLaunchConfig          --region us-east-1
AMI_SBIN=/tmp/sbin 

## Prepare the instance 
$AMI_SBIN/prep-cp-instance.sh 
. $AMI_SBIN/prepare-disks.sh 

## Wait for all nodes to come on-line
$AMI_SBIN/wait-for-child-resource.sh kafka-setup2 ZookeeperStack Nodes
$AMI_SBIN/wait-for-child-resource.sh kafka-setup2 BrokerStack Nodes
$AMI_SBIN/wait-for-child-resource.sh kafka-setup2 WorkerStack Nodes

## Now find the private IP addresses of all deployed nodes
##   (generating /tmp/cphosts and /tmp/<role> files)
$AMI_SBIN/gen-cluster-hosts.sh kafka-setup2

## Tag the instance (now that we're sure of launch index)
##   NOTE: ami_launch_index is correct only within a single subnet)
instance_id=$(curl -f http://169.254.169.254/latest/meta-data/instance-id)
ami_launch_index=$(curl -f http://169.254.169.254/latest/meta-data/ami-launch-index)
launch_node=$(grep -w `hostname -s` /tmp/brokers | awk '{print $2}')
if [ -n "$launch_node" ] ; then
  launch_index=${launch_node#*NODE}
else
  launch_index=${ami_launch_index}
fi
if [ -n "$instance_id" ] ; then
  instance_tag=awsqs-broker-${launch_index}
  aws ec2 create-tags --region us-east-1 --resources $instance_id --tags Key=Name,Value=$instance_tag
fi
## Run the steps to install the software, 
## then configure and start the services 
$AMI_SBIN/cp-install.sh 2> /tmp/cp-install.err 
$AMI_SBIN/cp-deploy.sh 2> /tmp/cp-deploy.err 

CONNECTOR_URLS= 
if [ -n "$CONNECTOR_URLS" ] ; then 
  for csrc in ${CONNECTOR_URLS//,/ } ; do 
    $AMI_SBIN/cp-retrieve-connect-jars.sh $csrc 2>&1 | tee -a /tmp/cp-retrieve-connect-jars.err 
  done 
fi

## [ OPTIONAL ] Open up ssh to allow direct login
#sed -i 's/ChallengeResponseAuthentication .*no$/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
#service sshd restart

## If all went well, signal success (must be done by ALL nodes in group)
cfn-signal -e 0 -r 'Confluent Platform node deployment complete' 'https://cloudformation-waitcondition-us-east-1.s3.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-east-1%3A383553647550%3Astack/kafka-setup2-BrokerStack-NA48RQ61P3GO/1f2d1e90-f192-11e8-b4e1-500c2854e035/NodesReadyHandle?AWSAccessKeyId=AKIAIIT3CWAIMJYUTISA&Expires=1543333457&Signature=BqRBNgwWUEjDuvIAiLvc39GmFIY%3D'

## Wait for all nodes to issue the signal
$AMI_SBIN/wait-for-resource.sh NodesReadyCondition 

## Signal back information for outputs (now that all nodes are up) 
$AMI_SBIN/post-cp-info.sh 'https://cloudformation-waitcondition-us-east-1.s3.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-east-1%3A383553647550%3Astack/kafka-setup2/c6d50000-f191-11e8-9c90-0a9be5775b42/ClusterInfoHandle?AWSAccessKeyId=AKIAIIT3CWAIMJYUTISA&Expires=1543333310&Signature=m10nyhNfEbvnT3U6sfbtUYW2CFA%3D'

