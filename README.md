dutch devops engineers environment
===================================
This script creates the base for a VPC setting up a HA environment using two availability zones, a NAT instance in each
zone and 1 bastion host.

Two dummy instances are created for test purposes.

This script will only work for the domain dutchdevops.net.

Prerequisites
--------------
You need to have:
- Python 
- Amazon AWS CLI   (sudo pip install awscli)
- jq               (brew install jq)
- jinja2           (sudo pip install jinja2)
- Power user and IAM privileges on your AWS account
- a route53 zone .dutchdevops.net.


INSTALL
-------
The script has only been tested on MacOS, so if you find any platform specific issues please let me know!

- checkout this repository 
- move into the directory ddelab
- now type:
``` bash
    bin/create-stack.sh -d student-name
```

When the script has completed, you can ssh into the jump host 

``` bash 
ssh-add stacks/<student-name>dutchdevopsnet/<studentname>.pem
ssh -A bastion.<student-name>.dutchdevops.net
```

also two DNS records have been created pointing to the load balancer.
