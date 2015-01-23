#!/bin/bash

export DOMAIN_NAME=
export STACK_NAME=
export KEY_NAME=
export REGION=eu-central-1
export STACK_DIR=stacks/

function parseCommandLine() {
	USAGE="Usage: $(basename $0) -d student-name  "

	while getopts "d:" OPT; do
		case $OPT in
			d)
				KEY_NAME=$OPTARG
				DOMAIN_NAME=${KEY_NAME}.dutchdevops.net
				STACK_NAME=$(echo $DOMAIN_NAME | sed -e 's/[^a-zA-Z0-9]//g')
				STACK_DIR=stacks/$STACK_NAME
				;;
			\*)
				echo $USAGE >&2
				exit 1
				;;
		esac
	done

	if [  -z "$DOMAIN_NAME" ] ; then
		echo $USAGE >&2
		exit 1
	fi
}

function createKeyPair() {
        SSH_PRIVATE_KEY=$(pwd)/$STACK_DIR/$KEY_NAME.pem
	if [ -z "$(aws --region $REGION ec2 describe-key-pairs  --key-names $KEY_NAME)" ]  ; then
		mkdir -p $STACK_DIR
		aws --region $REGION ec2 create-key-pair --key-name $KEY_NAME | \
			jq -r  '.KeyMaterial' | \
			sed 's/\\n/\r/g' > $STACK_DIR/$KEY_NAME.pem
		 chmod 0700 $STACK_DIR/$KEY_NAME.pem
	else
		if [ ! -f $STACK_DIR/$KEY_NAME.pem ] ; then
			echo ERROR: key pair $STACK_NAME already exist, but I do not have it in $STACK_DIR.
			exit 1
		fi
	fi
}

function getOrGenerateCertificate() {
	SSL_KEY_NAME=$(aws iam list-server-certificates | \
			jq -r "  .ServerCertificateMetadataList[] | select(.ServerCertificateName == \"$DOMAIN_NAME\") | .Arn ")

	if [ -z "$SSL_KEY_NAME" ] ; then
		mkdir -p $STACK_DIR
		SSL_KEY_NAME=$(
		umask 077
		cd $STACK_DIR
		openssl genrsa 1024 > $DOMAIN_NAME.key 2>/dev/null
		openssl req -nodes -newkey rsa:2048 -keyout $DOMAIN_NAME.key -subj /CN=$DOMAIN_NAME > $DOMAIN_NAME.csr 2>/dev/null
		openssl x509 -req -days 365 -in $DOMAIN_NAME.csr -signkey $DOMAIN_NAME.key > $DOMAIN_NAME.crt 2>/dev/null
		aws iam upload-server-certificate --server-certificate-name $DOMAIN_NAME \
						--certificate-body file://./$DOMAIN_NAME.crt  \
						--private-key file://./$DOMAIN_NAME.key | \
			jq -r '.ServerCertificateMetadata | .Arn'
		)
	fi
}

function getStackStatus() {
	aws --region $REGION cloudformation describe-stacks --stack-name $STACK_NAME 2>/dev/null | \
		jq -r '.Stacks[] | .StackStatus' 
}

function getNumberOfInstancesWithoutPrivateIp() {
	getHostTable | awk 'BEGIN { count=0; } { if ($3 == "null") count++; } END { print count; }'
}

function createStack() {
	python bin/render_template.py \
		--template ./config/cloudformation.template.jinja \
		> $STACK_DIR/cloudformation.template

	export SSL_KEY_NAME STACK_NAME REGION KEY_NAME
	PARAMETERS=$(cat <<!
[ { "ParameterKey": "SSLCertificateId", "ParameterValue": "$SSL_KEY_NAME", "UsePreviousValue": false },
  { "ParameterKey": "KeyName", "ParameterValue": "$KEY", "UsePreviousValue": false }
]
!)
	PARAMETERS="ParameterKey=SSLCertificateId,ParameterValue=$SSL_KEY_NAME,UsePreviousValue=false \
                    ParameterKey=KeyName,ParameterValue=$KEY_NAME,UsePreviousValue=false"

	STATUS=$(getStackStatus)
	if [ -z "$STATUS" ] ; then
		aws --region $REGION cloudformation create-stack \
			--stack-name $STACK_NAME \
			--template-body "$(cat $STACK_DIR/cloudformation.template)" \
			--parameters $PARAMETERS \
			--on-failure DO_NOTHING
	else
		echo WARN: Stack $STACK_NAME already exists in status $STATUS
	fi

	while [ CREATE_IN_PROGRESS == "$(getStackStatus)" ] ; do
		echo "INFO: create in progress. sleeping 15 seconds..."
		sleep 15
	done

	if [ "$(getStackStatus)" != CREATE_COMPLETE ] ; then
		echo "ERROR: failed to create stack: $(getStackStatus)"
		exit 1
	fi

	while [ $(getNumberOfInstancesWithoutPrivateIp) -gt 0 ] ; do
		echo "INFO: not all instances have a private ip address. sleep 10 seconds.."
		getHostTable
		sleep 10
	done
}

function getHostTable() {
	aws --region $REGION ec2 describe-instances --filters  Name=instance-state-name,Values=running Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME | \
	  jq  -r ' .Reservations[] | 
	.Instances[] |  
	select(.Tags[] |  .Key == "aws:cloudformation:logical-id" ) | 
	[
	(.Tags[] | 
		select(.Key == "aws:cloudformation:logical-id") | .Value), 
		if .PublicIpAddress then .PublicIpAddress else "null" end, 
		if .PrivateIpAddress then .PrivateIpAddress else "null" end
	] | 
	join("	")' | \
	sort
}



function getPublicIPAddress() {
	getHostTable | grep $1 | awk '{print $2}' | grep -v null
}

function getBastionIPAddresses() {
	getHostTable | grep -e Bastion | awk '{print $2}' | grep -v null
}

function getAllPrivateIPAddresses() {
	getHostTable | grep -v Bastion -v NAT | awk '{print $2}' | grep -v null
}




function generatePassword() {
	if [ ! -f $STACK_DIR/password.txt ] ; then
		echo "INFO: generating new random password for account"
		touch $STACK_DIR/password.txt
		chmod 0700 $STACK_DIR/password.txt
		openssl rand -base64 8 > $STACK_DIR/password.txt
	fi
	STACKATO_PASSWORD=$(cat $STACK_DIR/password.txt)
}


parseCommandLine $@
getOrGenerateCertificate
createKeyPair
createStack
