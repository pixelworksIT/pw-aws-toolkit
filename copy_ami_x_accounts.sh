#!/bin/bash
#
# Copyright 2017 Pixelworks Inc.
#
# Author: Simon Cheng Chi <cchi@pixelworks.com>
# Re-arranged by: Houyu Li <hyli@pixelworks.com>
#
# This script is to simplify the process of copying AMI from one
# AWS account to another.
# Before start, you should have AWS command line tool installed, and setup
# profile with access / secret keys of IAM user with proper permission for
# each AWS account.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

## Check configuration files
CONF_LOCAL="./copy_ami_x_accounts.conf"
if [ -f "$CONF_LOCAL" ]; then
    . "$CONF_LOCAL"
else
    echo "Configuration file not found!" >&2
    echo "Before the first run, do following to create the config file." >&2
    echo "    $ cp copy_ami_x_accounts.conf.dist \\" >&2
    echo "            copy_ami_x_accounts.conf" >&2
    echo "Then modify variables in the config file to match your AWS accounts." >&2
    exit 1
fi
## //

## Get the only argument as source AMI ID to be copied.
## Otherwise, print help message.
if [ -z "$1" ] || [[ "$1" == *"help"* ]]; then
    echo "Usage: $0 <source_ami_id>" >&2
    exit 1
else
    AMI_ID_SRC=$1
fi
## //

## Doing some checks before we start
### Check source AMI image existance
aws $AWSCLI_PROF_SRC ec2 describe-images \
    --image-ids "$AMI_ID_SRC"  >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "We cannot find the source AMI with the giving account profile!" >&2
    exit 2
fi

### Check AMI image existance in destination account with the same name
AMI_NAME_SRC=$(aws $AWSCLI_PROF_SRC ec2 describe-images \
    --image-ids "$AMI_ID_SRC" \
    --query Images[].Name \
    --output text)
AMI_ID_DST=$(aws $AWSCLI_PROF_DST ec2 describe-images \
    --filter Name=name,Values="$AMI_NAME_SRC" \
    --query Images[].ImageId \
    --output text)
if ! [ -z "$AMI_ID_DST" ]; then
    echo "In destination account, we find an AMI with the same name!" >&2
    exit 2
fi
## //

## Get some more information about source AMI
### The description
AMI_DESC_SRC=$(aws $AWSCLI_PROF_SRC ec2 describe-images \
    --image-ids "$AMI_ID_SRC" \
    --query Images[].Description \
    --output text)
### The snapshot ID
### TODO: Need to deal with multiple snapshots in AMI
TMP_F_AMI_SNAPS_SRC=`mktemp`
aws $AWSCLI_PROF_SRC ec2 describe-images \
    --image-ids $AMI_ID_SRC \
    --query Images[].BlockDeviceMappings[].[DeviceName,Ebs.SnapshotId] \
    --output text > "$TMP_F_AMI_SNAPS_SRC"
### Example content in $TMP_F_AMI_SNAPS_SRC
#/dev/sda1	snap-5e27ef04
#/dev/sdf	snap-103dbc49
#/dev/sdg	snap-c9d89433
#/dev/sdh	snap-9825e165

SNAP_IDS_LCP=`cat "$TMP_F_AMI_SNAPS_SRC" |awk '{ print $2 }'`
## //

## Share the snapshots to destination account
for SNAP_ID_LCP in $SNAP_IDS_LCP; do
    aws $AWSCLI_PROF_SRC ec2 modify-snapshot-attribute \
        --attribute createVolumePermission \
        --operation-type add \
        --snapshot-id "$SNAP_ID_LCP" \
        --user-ids "$AWS_ACCT_ID_DST"
    if [ $? -ne 0 ]; then
        echo "Failed to share snapshot $SNAP_ID_LCP. Exit!" >&2
        exit 3
    fi
done
## //

## In the destination account, copy the shared snapshot to destination
## local.
TMP_F_AMI_SNAPS_LCP_DST=`mktemp`
TMP_F_SNAP_IDS_LCP_DST=`mktemp`
while IFS='' read -r l_snapinfo || [[ -n "$l_snapinfo" ]]; do
    AMI_SNAP_ID_SRC_LCP=`echo $l_snapinfo |awk '{ print $2 }'`
    AMI_SNAP_ID_LCP_DST=$(aws $AWSCLI_PROF_DST ec2 copy-snapshot \
        --source-region "$REGION_FROM" \
        --source-snapshot-id "$AMI_SNAP_ID_SRC_LCP" \
        --destination-region "$REGION_TO" \
        --query SnapshotId \
        --output text)
    echo "$l_snapinfo $AMI_SNAP_ID_LCP_DST" >> "$TMP_F_AMI_SNAPS_LCP_DST"
    echo -n "$AMI_SNAP_ID_LCP_DST " >> "$TMP_F_SNAP_IDS_LCP_DST"
done < "$TMP_F_AMI_SNAPS_SRC"

### Waiting for the copy process to finish
SNAP_IDS_LCP_DST=`cat "$TMP_F_SNAP_IDS_LCP_DST"`
rm -f "$TMP_F_SNAP_IDS_LCP_DST"

SNAP_CP_DONE="any sting applies"
while ! [ -z "$SNAP_CP_DONE" ]; do
    sleep 5
    SNAP_CP_DONE=$(aws $AWSCLI_PROF_DST ec2 describe-snapshots \
        --snapshot-ids $SNAP_IDS_LCP_DST \
        --query Snapshots[].State \
        --output text |grep -v "completed")
    SNAP_CP_ERR=`echo $SNAP_CP_DONE |grep "error"`
    if ! [ -z "$SNAP_CP_ERR" ]; then
        echo "Copy encounters error. (DST) Exit!" >&2
        for SNAP_ID_LCP_1 in $SNAP_IDS_LCP_DST; do
            aws $AWSCLI_PROF_DST ec2 delete-snapshot \
                --snapshot-id "$SNAP_ID_LCP_1"
        done
        rm -f "$TMP_F_AMI_SNAPS_LCP_DST"
        exit 3
    fi
done
## //

## Register new AMI image in destination account
### Get AMI root device name
### The the first snapshot as root device
AMI_ROOT_DEV=`head -n 1 "$TMP_F_AMI_SNAPS_LCP_DST" |awk '{ print $1 }'`
### Prepare block device mapping string
AMI_BLOCK_MAP=""
while IFS='' read -r l_snapinfo || [[ -n "$l_snapinfo" ]]; do
    AMI_BLOCK_DEV=`echo $l_snapinfo |awk '{ print $1 }'`
    AMI_BLOCK_SNAP_ID=`echo $l_snapinfo |awk '{ print $3 }'`
    AMI_BLOCK_MAP="$AMI_BLOCK_MAP"" ""DeviceName=""$AMI_BLOCK_DEV"",Ebs={SnapshotId=""$AMI_BLOCK_SNAP_ID""}"
done < "$TMP_F_AMI_SNAPS_LCP_DST"

AMI_NAME_DST="$AMI_NAME_SRC"
AMI_DESC_DST="$AMI_DESC_SRC"
AMI_ID_DST=$(aws $AWSCLI_PROF_DST --region "$REGION_TO" \
    ec2 register-image \
    --architecture x86_64 \
    --root-device-name "$AMI_ROOT_DEV" \
    --block-device-mappings $AMI_BLOCK_MAP \
    --description "$AMI_DESC_DST" \
    --name "$AMI_NAME_DST" \
    --virtualization-type hvm \
    --ena-support \
    --query ImageId \
    --output text)
## //

## Clean up
rm -f "$TMP_F_AMI_SNAPS_LCP_DST"
## //

if [ -z "$AMI_ID_DST" ]; then
    echo "Create image in destination account failed!" >&2
    for SNAP_ID_LCP_1 in $SNAP_IDS_LCP_DST; do
        aws $AWSCLI_PROF_DST ec2 delete-snapshot \
            --snapshot-id "$SNAP_ID_LCP_1"
    done
    exit 3
fi

echo "The new AMI image $AMI_ID_DST is created in target account."

exit 0
