#!/bin/bash
# cchi@pixelworks.com wrote on June 26.2017  under  Apache 2.0 License
#https://aws.amazon.com/blogs/security/how-to-create-a-custom-ami-with-encrypted-amazon-ebs-snapshots-and-share-it-with-other-accounts-and-regions/
#  please setup your .aws/config like
#  [profile us0 ] 
#  region = us-west-2
#  [profile us2 ]
#  region = us-west-2
#  please also setup .aws/credential with us0 and us2,   
#  
#
# please setup source profile and destination profile
SRC_P=
DST_P=

# SOURCE AWS ID and TARGET AWS ID.  
SOURCE_ID=000000000000
TARGET_ID=000000000000


SOURCE_REGION=us-west-2
TARGET_REGION=us-west-2

# kms ID   somehow very hard to get ID from alias , So just least here.
SOURCE_KMS_ID="00000000-0000-0000-0000-000000000000"
TARGET_KMS_ID="00000000-0000-0000-0000-000000000000"

if [ "$1" == "" ] || [[ "$1" == *"help"* ]] 
then
echo "Usage: $0 AMI-ID "; exit 0
else
SOURCE_AMI=$1
fi

date

aws --profile $SRC_P ec2 describe-images --image-ids $SOURCE_AMI  &>/dev/null || \
	{ echo "AMI not exisit" ; exit 0; }

NEW_NAME=$(aws --profile $SRC_P ec2 describe-images --image-ids $SOURCE_AMI --query Images[].Name --output text)
NEW_DESCRIPTION=$(aws --profile $SRC_P ec2 describe-images --image-ids $SOURCE_AMI --query Images[].Description --output text)

## check if the name of AMI exist in DST 
TMP_DST_AMI_ID=$(aws --profile $DST_P ec2 describe-images --filter Name=name,Values="$NEW_NAME" --query Images[].ImageId --output text)
[ "$TMP_DST_AMI_ID" != "" ]  && { echo "AMI name exist in DST"; exit 0; }




TMP_NAME=$SOURCE_AMI.tmp

TMP_SOURCE_AMI=$(aws --profile $SRC_P ec2 copy-image --encrypted --kms-key-id $SOURCE_KMS_ID --name $TMP_NAME --source-image-id $SOURCE_AMI --source-region $SOURCE_REGION --query ImageId --output text)



PERCENTAGE=""
while [ "$PERCENTAGE" != "100%" ]
do
sleep 10
PERCENTAGE=$(aws --profile $SRC_P ec2 describe-snapshots --filters Name=description,Values=\*$TMP_SOURCE_AMI\* --query Snapshots[].Progress --output text)
done
 
SRC_SNAP_ID=$(aws --profile $SRC_P ec2 describe-snapshots --filters Name=description,Values=\*$TMP_SOURCE_AMI\* --query Snapshots[].SnapshotId --output text)

#echo "SNAP="$SRC_SNAP_ID

aws --profile $SRC_P ec2 modify-snapshot-attribute --attribute createVolumePermission --operation-type add --snapshot-id $SRC_SNAP_ID --user-ids $TARGET_ID


TMP_DESCRIPTION="simoncopy2"
DST_SNAP_ID=$(aws --region $TARGET_REGION --profile $DST_P ec2 copy-snapshot --source-region $SOURCE_REGION --source-snapshot-id $SRC_SNAP_ID --description $TMP_DESCRIPTION --encrypted --kms-key-id $TARGET_KMS_ID --query SnapshotId --output text)

PERCENTAGE=""
while [ "$PERCENTAGE" != "100%" ]
do
sleep 10
PERCENTAGE=$(aws --profile $DST_P ec2 describe-snapshots --snapshot-ids $DST_SNAP_ID --query Snapshots[].Progress --output text)
done



NEW_AMI_ID=$(aws --region $TARGET_REGION --profile $DST_P ec2 register-image --architecture x86_64 --root-device-name /dev/sda1 --block-device-mappings DeviceName=/dev/sda1,Ebs={SnapshotId=$DST_SNAP_ID} --description "$NEW_DESCRIPTION" --name $NEW_NAME --virtualization-type hvm --query ImageId --output text)


echo $NEW_AMI_ID 


###now cleanup
aws --profile $SRC_P ec2 deregister-image --image-id $TMP_SOURCE_AMI
aws --profile $SRC_P ec2 delete-snapshot --snapshot-id $SRC_SNAP_ID

date
