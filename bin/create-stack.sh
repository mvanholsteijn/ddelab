#!/bin/bash

export DOMAIN_NAME=
export STACK_NAME=
export KEY_NAME=
export REGION=eu-central-1
export STACK_DIR=stacks/

function parseCommandLine() {
	USAGE="Usage: $(basename $0) -d domain "

	while getopts "r:d:" OPT; do
		case $OPT in
			r)
				REGION=$OPTARG
				;;
			d)
				DOMAIN_NAME=${OPTARG}
				KEY_NAME=$(echo $OPTARG | sed -e 's/\([^\.]*\).*/\1/g')
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

function getOrGenerateWildcardCertificate() {
	WILDCARD_DOMAIN="$(echo $DOMAIN_NAME | sed -e 's/[^\.]*\.\(.*\)/\1/g')"
	SSL_KEY_NAME=$(aws iam list-server-certificates | \
			jq -r "  .ServerCertificateMetadataList[] | select(.ServerCertificateName == \"$WILDCARD_DOMAIN\") | .Arn ")

	if [ -z "$SSL_KEY_NAME" ] ; then
	
		export CERT_DIR=$STACK_DIR/certificates
		mkdir -p $CERT_DIR
		SSL_KEY_NAME=$(
		umask 077
		cd $CERT_DIR
		openssl genrsa 1024 > $WILDCARD_DOMAIN.key 2>/dev/null
		openssl req -nodes -newkey rsa:2048 -keyout $WILDCARD_DOMAIN.key -subj /CN="*.$WILDCARD_DOMAIN" > $WILDCARD_DOMAIN.csr 2>/dev/null
		openssl x509 -req -days 365 -in $WILDCARD_DOMAIN.csr -signkey $WILDCARD_DOMAIN.key > $WILDCARD_DOMAIN.crt 2>/dev/null
		aws iam upload-server-certificate --server-certificate-name "$WILDCARD_DOMAIN" \
						--certificate-body file://./$WILDCARD_DOMAIN.crt  \
						--private-key file://./$WILDCARD_DOMAIN.key | \
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
		aws --region $REGION cloudformation describe-stack-events \
			--stack-name $STACK_NAME | \
			jq -r '.StackEvents[] | select(.ResourceStatus == "CREATE_FAILED") | .ResourceStatusReason'
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


function checkHostedZoneExists() {
	DOMAIN=$(echo $DOMAIN_NAME | sed -e 's/[^\.]*.\(.*\)/\1/g')
	EXISTS=$( aws route53 list-hosted-zones  | \
			jq -r '.HostedZones[] | .Name' | \
			grep "^$DOMAIN.\$" )

	if [ -z "$EXISTS" ] ; then
		echo ERROR hosted zone for $DOMAIN does not exist in route53.
		exit 1
	fi
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
checkHostedZoneExists
getOrGenerateWildcardCertificate
createKeyPair
createStack
