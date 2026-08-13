*** BELOW Instructions on creating via Cloud formation template ***
*** The attached word doc allows you do do this via cli instead ***
******** NOTE **********

RHEL 9 AMI (ami-035032ea878eca201) — Red Hat periodically releases new RHEL 9 images. This one works today. If you run this 6 months from now, re-check with:
aws ec2 describe-images --owners 309956199498 --filters "Name=name,Values=RHEL-9*GA*" "Name=architecture,Values=x86_64" "Name=state,Values=available" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region us-east-2

****** REPLACE THE AMI for RHEL 9 in the YAML file *********

F5 AMI (ami-0a330553d7e1d3c3f) — F5 also releases new BIG-IP images periodically. Same deal — works today, re-check before deploying in the future with:
aws ec2 describe-images --owners 679593333241 --filters 'Name=name,Values=*BIGIP*Good*25Mbps*' 'Name=state,Values=available' --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region us-east-2


1 — Get your F5 AMI ID:

aws ec2 describe-images --owners 679593333241 --filters 'Name=name,Values=*BIGIP*Good*25Mbps*' 'Name=state,Values=available' --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text

2 — Make sure your key pair exists:

aws ec2 describe-key-pairs --key-names mcropsey-key --query 'KeyPairs[0].KeyName' --output text

Then deploy the whole stack in one command:

aws cloudformation create-stack \
  --stack-name mcropsey-lab \
  --template-body file://mcropsey-lab.yaml \
  --parameters \
    ParameterKey=MyIP,ParameterValue=$(curl -s ifconfig.me)/32 \
    ParameterKey=KeyName,ParameterValue=mcropsey-key \
    ParameterKey=F5AMI,ParameterValue=<YOUR_F5_AMI_ID> \
  --region us-east-2

  Watch the deployment:

  aws cloudformation wait stack-create-complete --stack-name mcropsey-lab --region us-east-2
aws cloudformation describe-stacks --stack-name mcropsey-lab --query 'Stacks[0].Outputs' --output table --region us-east-2

The outputs will give you every IP and SSH command you need. After that the only manual step is the BIG-IP tmsh configuration (VLANs, self IPs, pool, virtual server).

After the stack deploys — still manual in BIG-IP tmsh:

Set admin password
Create VLANs, self IPs, monitor, pool, virtual server

That part can't be automated via CloudFormation — it's BIG-IP internal config. Everything AWS-side is fully automated.