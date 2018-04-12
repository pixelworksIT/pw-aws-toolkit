#!/bin/bash
#
# Copyright 2017 Pixelworks Inc.
#
# Author: Houyu Li <hyli@pixelworks.com>
#
# This script is to simplify the process of migrating / syncing S3 bucket from one
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
CONF_LOCAL="./sync_s3_x_accounts.conf"
if [ -f "$CONF_LOCAL" ]; then
    . "$CONF_LOCAL"
else
    echo "Configuration file not found!" >&2
    echo "Before the first run, do following to create the config file." >&2
    echo "    $ cp sync_s3_x_accounts.conf.dist \\" >&2
    echo "            sync_s3_x_accounts.conf" >&2
    echo "Then modify variables in the config file to match your AWS accounts." >&2
    exit 1
fi

BKT_X_ACCT_PLC_TPL="./sync_s3_x_accounts-src_bkt_policy.tpl.json"
if ! [ -f "$BKT_X_ACCT_PLC_TPL" ]; then
    echo "Missing source bucket policy template." >&2
    exit 1
fi
## //

## Some functions
### Restore settings of source S3 bucket
function restore_s3_bkt_src {
    aws $AWSCLI_PROF_SRC s3api delete-bucket-policy \
        --bucket "$1"
    ### TODO: Restore original bucket policy if any
}
## //

## Get the only argument as source S3 bucket name to be copied.
## Otherwise, print help message.
if [ -z "$1" ] || [[ "$1" == *"help"* ]]; then
    echo "Usage: $0 <source_bucket_name>" >&2
    exit 1
else
    S3_BKT_SRC=$1
fi
## //


## Doing some checks before we start
### Check source S3 bucket existance
S3_BKT_SRC_CK=$(aws $AWSCLI_PROF_SRC s3 ls \
    |awk '{ print $3 }' \
    |grep -w "$S3_BKT_SRC" 2>/dev/null)
if [ -z "$S3_BKT_SRC_CK" ]; then
    echo "We cannot find the source S3 bucket with the giving account profile!" >&2
    exit 2
fi
## //

## TODO: Need more work to copy over every aspect of source bucket to dest bucket

## Put bucket policy to source bucket to allow read from dest AWS account
### Prepare the policy
TMP_BKT_X_ACCT_PLC=`mktemp`
cat "$BKT_X_ACCT_PLC_TPL" \
    |sed -e 's/<source_bucket>/'"$S3_BKT_SRC_CK"'/g' \
    |sed -e 's/<src_aws_account_id>/'"$AWS_ACCT_ID_DST"'/g' > "$TMP_BKT_X_ACCT_PLC"

### Put the bucket policy
### TODO: This will override original policy, need backup first
aws $AWSCLI_PROF_SRC s3api put-bucket-policy \
    --bucket "$S3_BKT_SRC_CK" \
    --policy "file://""$TMP_BKT_X_ACCT_PLC"
if [ $? -ne 0 ]
then
    rm -f "$TMP_BKT_X_ACCT_PLC"
    echo "Failed to upload policy for source bucket." >&2
    exit 3
fi
rm -f "$TMP_BKT_X_ACCT_PLC"
## //

## Test access the bucket from destination AWS account
aws $AWSCLI_PROF_DST s3 ls "s3://""$S3_BKT_SRC_CK"
if [ $? -ne 0 ]
then
    echo "Cannot access source bucket in destination AWS account." >&2
    exit 3
fi
## //

## Create new bucket in destination AWS account
S3_BKT_DST="$S3_BKT_SRC_CK""-""$S3_BKT_DST_SUFF"
aws $AWSCLI_PROF_DST s3api create-bucket \
    --bucket "$S3_BKT_DST" \
    --create-bucket-configuration "LocationConstraint=""$REGION_TO"
if [ $? -ne 0 ]
then
    ### Restore settings of source S3 bucket
    restore_s3_bkt_src "$S3_BKT_SRC_CK"
    echo "Create new bucket in destination AWS account failed." >&2
    exit 3
fi
## //

## Start sync
aws $AWSCLI_PROF_DST s3 sync \
    "s3://""$S3_BKT_SRC_CK" \
    "s3://""$S3_BKT_DST"
if [ $? -ne 0 ]
then
    ### Restore settings of source S3 bucket
    restore_s3_bkt_src "$S3_BKT_SRC_CK"
    echo "Sync failed." >&2
    exit 3
fi

## Restore settings of source S3 bucket
restore_s3_bkt_src "$S3_BKT_SRC_CK"

exit 0

