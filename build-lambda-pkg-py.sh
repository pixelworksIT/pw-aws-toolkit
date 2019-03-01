#!/usr/bin/env bash
#
# Copyright 2019 Pixelworks Inc.
#
# Author: Houyu Li <hyli@pixelworks.com>
#
# This script help you to make a AWS lambda package that runs Python program
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

#-------- Customizable variables --------#

# The final lambda package file
LAMBDA_PKG_FILE="lambda_pkg.zip"

# AWS EC2 parameters
## The following AMI is stated on page
##   https://docs.aws.amazon.com/lambda/latest/dg/current-supported-versions.html
EC2_IMAGE_ID="ami-aa5ebdd2" # amzn-ami-hvm-2017.03.1.20170812-x86_64-gp2
EC2_INSTANCE_TYPE="t2.micro"
EC2_KEY_NAME=""
EC2_SECURITY_GROUP_IDS=""
EC2_SUBNET_ID=""
EC2_IAM_INSTANCE_PROFILE="Name="

# SSH user
SSH_USER="ec2-user"
# Using "public" or "private" IP for SSH
SSH_PRIV_PUB_IP="public"
# Local SSH key file for remote to the EC2 instance
LOCAL_KEY_FILE=""

# AWS command credential profile
AWSCLI_PROF="--profile default"

# Generally, you do not need to modify following Python related options and vars.
# But in case you need a different version of Python.
# Available Python versions
declare -A PYTHON_VERS_OPTS
PYTHON_VERS_OPTS[1]="    1) Python 2.7"
PYTHON_VERS_OPTS[2]="    2) Python 3.4"
PYTHON_VERS_OPTS[3]="    3) Python 3.5"
PYTHON_VERS_OPTS[4]="    4) Python 3.6"

# Default select Python version
DEFAUT_PYTHON_VER=4

# Python yum packages to install
declare -A PYTHON_PKGS
PYTHON_PKGS[1]="python27 python27-pip"
PYTHON_PKGS[2]="python34 python34-pip"
PYTHON_PKGS[3]="python35 python35-pip"
PYTHON_PKGS[4]="python36 python36-pip"

# Python binaries
declare -A PYTHON_BINS
PYTHON_BINS[1]="/usr/bin/python2.7"
PYTHON_BINS[2]="/usr/bin/python3.4"
PYTHON_BINS[3]="/usr/bin/python3.5"
PYTHON_BINS[4]="/usr/bin/python3.6"

# Python setup commands
declare -A PYTHON_SETUP_CMDS
PYTHON_SETUP_CMDS[1]="yum -y install ${PYTHON_PKGS[1]}""\n""update-alternatives --set python ${PYTHON_BINS[1]}""\n"
PYTHON_SETUP_CMDS[2]="yum -y install ${PYTHON_PKGS[2]}""\n""update-alternatives --set python ${PYTHON_BINS[2]}""\n"
PYTHON_SETUP_CMDS[3]="yum -y install ${PYTHON_PKGS[3]}""\n""update-alternatives --set python ${PYTHON_BINS[3]}""\n"
PYTHON_SETUP_CMDS[4]="yum -y install ${PYTHON_PKGS[4]}""\n""update-alternatives --set python ${PYTHON_BINS[4]}""\n"

#-------- Do not edit below this line --------#

# Current directory
BUILD_DIR=$(dirname $(realpath -s "$0"))

# Just make sure we delete the old package
rm -f "$BUILD_DIR""/""$LAMBDA_PKG_FILE"

# We need a clean screen
clear

# Total number of available Python versions
n_opts=1
N_PYTHON_VERS=0
while true; do
	if [ -z "${PYTHON_VERS_OPTS[$n_opts]}" ]; then
		break
	fi
	N_PYTHON_VERS=$n_opts
	n_opts=$(expr $n_opts + 1)
done

# Select Python version
while true; do
	echo ""
	echo "Please select Python version to use: "
	for idx in $(seq 1 4); do
		echo "${PYTHON_VERS_OPTS[$idx]}"
	done
	echo -n "Input number to choose [ Enter = 4 ]: "
	# Prompt for selection
	read USER_PYTHON_VER
	# If no input, go default
	if [ -z "$USER_PYTHON_VER" ]; then
		USER_PYTHON_VER=$DEFAUT_PYTHON_VER
		break
	fi
	# Validate user input
	VALID_USER_SEL=$(echo $USER_PYTHON_VER |grep -P "^[0-9]+$")
	if ! [ -z "$VALID_USER_SEL" ]; then
		# The user input is valid
		if [ $VALID_USER_SEL -ge 1 ] && [ $VALID_USER_SEL -le $N_PYTHON_VERS ]; then
			# User made a valid choice. Just exit loop.
			break
		fi
		# Otherwise, show the error and make selection again
		echo ""
		echo "[Error] Selection out of range [1-$N_PYTHON_VERS]. Please try again."
		continue
	fi
	# The user input is invalid. Show error and make selection again
	echo ""
	echo "[Error] Input invalid. Please try again."
done

# The selected Python setup command
PYTHON_SETUP_CMD=${PYTHON_SETUP_CMDS[$USER_PYTHON_VER]}
PYTHON_BIN_NAME=$(basename ${PYTHON_BINS[$USER_PYTHON_VER]})
#echo $PYTHON_SETUP_CMD

# Prompt for extra Python modules to be installed
PYTHON_EXT_MODS_CMD=""
while true; do
	echo ""
	echo -n "Do you want to install extra Python modules [y/N]: "
	read MORE_MODULE
	# If no input, default to not install any more modules
	if [ -z "$MORE_MODULE" ]; then
		MORE_MODULE="N"
	fi
	# Only get the first input character
	MORE_MODULE=${MORE_MODULE:0:1}
	# And compare in lower case
	if [ "${MORE_MODULE,,}" == "y" ]; then
		# Yes, we will install something else
		while true; do
			THIS_PYTHON_MOD_CMD=""
			# Ask for module installation method
			echo ""
			echo "Please select module installation method"
			echo "    1) pip"
			echo "    2) git"
			echo "    3) == Cancel =="
			echo -n "Choice [ Enter = 1 ]: "
			read USER_MOD_INSTALL_METHOD
			# If no input, use default
			if [ -z "$USER_MOD_INSTALL_METHOD" ]; then
				USER_MOD_INSTALL_METHOD=1
			fi
			# Set install method
			if [ $USER_MOD_INSTALL_METHOD -eq 1 ]; then
				# 1 = pip
				MOD_INSTALL_METHOD="pip"
			elif [ $USER_MOD_INSTALL_METHOD -eq 2 ]; then
				# 2 = git
				MOD_INSTALL_METHOD="git"
			elif [ $USER_MOD_INSTALL_METHOD -eq 3 ]; then
				# 3 = Well, something changed. Exit this loop
				echo ""
				echo "User cancel."
				break
			else
				# Unknown input. Restart loop.
				echo ""
				echo "[Error] Unknown input, try again."
				continue
			fi
			
			# Ask for module name or git repo url
			MOD_SOURCE=""
			while true; do
				echo ""
				echo -n "Please input pip installable module name or git clone url [ 'q' + Enter = Cancel ]: "
				read USER_MOD_SOURCE
				# If we did not get any input, restart loop
				if [ -z "$USER_MOD_SOURCE" ]; then
					echo ""
					echo "[Error] No input detected. Try again."
					continue
				fi
				if [ "$USER_MOD_SOURCE" == "q" ]; then
					# User cancel input
					echo ""
					echo "User cancel."
				else
					# Normal input
					MOD_SOURCE="$USER_MOD_SOURCE"
				fi
				# What ever input we got, just exit the loop.
				break
			done
			# Any input, we will append to PYTHON_EXT_MODS
			if ! [ -z "$MOD_SOURCE" ]; then
				# Generate installation command to THIS_PYTHON_MOD
				if [ "$MOD_INSTALL_METHOD" == "pip" ]; then
					# Install using pip
					THIS_PYTHON_MOD_CMD="$PYTHON_BIN_NAME"" -m pip install ""\"$MOD_SOURCE\"""\n"
				fi
				if [ "$MOD_INSTALL_METHOD" == "git" ]; then
					# Install using git
					THIS_PYTHON_MOD_CMD="git -c http.sslVerify=false clone ""\"$MOD_SOURCE\"""\n"
					# Get the clone dir
					GIT_NAME=$(basename "$MOD_SOURCE")
					CLONE_DIR=${GIT_NAME%.git}
					# Install it
					THIS_PYTHON_MOD_CMD="$THIS_PYTHON_MOD_CMD""cd \"$CLONE_DIR\"""\n"
					THIS_PYTHON_MOD_CMD="$THIS_PYTHON_MOD_CMD""$PYTHON_BIN_NAME"" -m pip install .""\n"
					THIS_PYTHON_MOD_CMD="$THIS_PYTHON_MOD_CMD""cd ..""\n"
					THIS_PYTHON_MOD_CMD="$THIS_PYTHON_MOD_CMD""rm -rf \"$CLONE_DIR\"""\n"
				fi
				# Finally, append THIS_PYTHON_MOD to PYTHON_EXT_MODS_CMD
				PYTHON_EXT_MODS_CMD="$PYTHON_EXT_MODS_CMD""$THIS_PYTHON_MOD_CMD"
			fi
			# Finally, back to main extra module loop
			break
		done
	else
		# The answer is not "y". Then we will not install any more modules.
		echo ""
		echo "Not installing any more Python modules."
		break
	fi
done
#echo -e $PYTHON_EXT_MODS_CMD

# Prompt for location of the default lambda entry script lambda_function.py
ADD_CODE_CMD=""
CODE_DIR="$BUILD_DIR"
while true; do
	echo ""
	echo "Now please tell the path of 'lambda_function.py'."
	echo "Till now, this script only supports the default filename as used in AWS Lambda."
	echo "Only input the full path, without the filename 'lambda_function.py'."
	echo "By default, we will search the file in path same as the build script."
	echo "Now please type in the path [ Enter = $BUILD_DIR ]: "
	read USER_CODE_DIR
	# Any input, assign to CODE_DIR
	if ! [ -z "$USER_CODE_DIR" ]; then
		CODE_DIR="$USER_CODE_DIR"
	fi
	# Check user input code dir and search for file 'lambda_function.py'
	if ! [ -d "$CODE_DIR" ]; then
		# Test path is not directory or existance
		echo ""
		echo "[Error] The path does not exist or is not a directory. Retry."
		continue
	fi
	if ! [ -f "$CODE_DIR""/lambda_function.py" ]; then
		# Cannot find lambda_function.py in the given path
		echo ""
		echo "[Error] Cannot find lambda_function.py in $CODE_DIR . Retry."
		continue
	fi
	# Found the lambda_function.py and exit the loop
	echo ""
	echo "Found $CODE_DIR/lambda_function.py ."
	break
done
# Generate the command to add this script
ADD_CODE_CMD="zip -g \"$BUILD_DIR/$LAMBDA_PKG_FILE\" \"$CODE_DIR/lambda_function.py\"""\n"

# Prompt for extra files and directories to be included in the package.
ADD_EXT_FILES_CMD=""
while true; do
	echo ""
	echo -n "Do you want to add extra files / folders to the package? [y/N]: "
	read MORE_FILES
	# If no input, default to not add any more files
	if [ -z "$MORE_FILES" ]; then
		MORE_FILES="N"
	fi
	# Only get the first input character
	MORE_FILES=${MORE_FILES:0:1}
	# And compare in lower case
	if [ "${MORE_FILES,,}" == "y" ]; then
		# Yes, we will add some more files
		while true; do
			ADD_THIS_FILE_CMD=""
			echo ""
			echo "Please input the path of the file / folder [ 'q' + Enter = Cancel ]: "
			read THIS_FILE
			# If we did not get any input, restart loop
			if [ -z "$THIS_FILE" ]; then
				echo ""
				echo "[Error] No input detected. Try again."
				continue
			fi
			if [ "$THIS_FILE" == "q" ]; then
				# User cancel input
				echo ""
				echo "User cancel."
			else
				# Normal input, check file or folder existance
				THIS_FILE=$(realpath "$THIS_FILE")
				if [ -d "$THIS_FILE" ]; then
					# It's a directory
					THIS_DIR_PATH=$(dirname "$THIS_FILE")
					THIS_DIR_NAME=$(basename "$THIS_FILE")
					ADD_THIS_FILE_CMD="cd \"$THIS_DIR_PATH\"""\n"
					ADD_THIS_FILE_CMD="$ADD_THIS_FILE_CMD""zip -g -r \"$BUILD_DIR/$LAMBDA_PKG_FILE\" ./""$THIS_DIR_NAME""\n"
					ADD_THIS_FILE_CMD="$ADD_THIS_FILE_CMD""cd -""\n"
				elif [ -f "$THIS_FILE" ]; then
					# It's a normal file
					ADD_THIS_FILE_CMD="zip -g \"$BUILD_DIR/$LAMBDA_PKG_FILE\" \"$THIS_FILE\"""\n"
				else
					# File not found error
					echo ""
					echo "[Error] File / directory not found. Try again."
					continue
				fi
				# Append to ADD_EXT_FILES_CMD
				ADD_EXT_FILES_CMD="$ADD_EXT_FILES_CMD""$ADD_THIS_FILE_CMD"
			fi
			# What ever input we got, just exit the loop.
			break
		done
	else
		# The answer is not "y". Then we will not add any more files.
		echo ""
		echo "Not adding any more files."
		break
	fi
done
#echo -e $ADD_EXT_FILES_CMD

# OK. We are now having all information to build the package. Now generate the user
#   data and launch an EC2 to build it
F_USER_DATA=$(mktemp)

# Add content to userdata script
cat > "$F_USER_DATA" <<EOS
#!/usr/bin/env bash
cd /root
yum -y install git
EOS

echo -n -e "$PYTHON_SETUP_CMD" >> "$F_USER_DATA"

cat >> "$F_USER_DATA" <<EOS
${PYTHON_BINS[$USER_PYTHON_VER]} -m pip install awscli
${PYTHON_BINS[$USER_PYTHON_VER]} -m pip install virtualenv
TMP_VENV=\$(mktemp -d)
/usr/local/bin/virtualenv -p "${PYTHON_BINS[$USER_PYTHON_VER]}" "\$TMP_VENV"
source "\$TMP_VENV""/bin/activate"
EOS

echo -n -e $PYTHON_EXT_MODS_CMD>> "$F_USER_DATA"

cat >> "$F_USER_DATA" <<EOS
PY_LIB=\$($PYTHON_BIN_NAME -c "import sys; print(sys.path[-1])")
cd "\$PY_LIB"
TMP_PKG=\$(mktemp -u --suffix=zip)
zip -g -r "\$TMP_PKG" .
cd -
deactivate
rm -rf "\$TMP_VENV"
mv "\$TMP_PKG" "/tmp/""$LAMBDA_PKG_FILE"
chmod 644 "/tmp/""$LAMBDA_PKG_FILE"
EOS
#cat "$F_USER_DATA"

# Now launch EC2 instance to build the package
NEW_INST_ID=$(aws $AWSCLI_PROF ec2 run-instances \
	--image-id "$EC2_IMAGE_ID" \
	--instance-type "$EC2_INSTANCE_TYPE" \
	--key-name "$EC2_KEY_NAME" \
	--security-group-ids $EC2_SECURITY_GROUP_IDS \
	--subnet-id "$EC2_SUBNET_ID" \
	--iam-instance-profile "$EC2_IAM_INSTANCE_PROFILE" \
	--user-data "file://""$F_USER_DATA" \
	--instance-initiated-shutdown-behavior "terminate" \
	--count 1 \
	--query Instances[0].InstanceId \
	--output text)

# Waiting for it going to "running" state
echo -n "Waiting for instance up "
while true; do
	# Query the instance's IP addresses and state
	INSTANCE_INFO=$(aws $AWSCLI_PROF ec2 describe-instances \
		--instance-ids $NEW_INST_ID \
		--query Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,State.Name] \
		--output text)
	INSTANCE_STATE=$(echo $INSTANCE_INFO |awk '{ print $3 }')
	if [ "${INSTANCE_STATE,,}" == "running" ]; then
		echo " running"
		break
	fi
	# A dummy tick dot
	for tick in $(seq 1 10); do
		echo -n "."
		sleep 1
	done
done
# The instance is up and running, we do not need the userdata script
rm -f "$F_USER_DATA"
# Get private and public IP address of the instance
INSTANCE_PRIV_IP=$(echo $INSTANCE_INFO |awk '{ print $1 }')
INSTANCE_PUB_IP=$(echo $INSTANCE_INFO |awk '{ print $2 }')
# By default, we use private IP for SSH
SSH_IP=$INSTANCE_PRIV_IP
# If set to use public IP, then we use public IP
if [ "${SSH_PRIV_PUB_IP,,}" == "public" ]; then
	SSH_IP=$INSTANCE_PUB_IP
fi

# Detect the LAMBDA_PKG_FILE
echo -n "Waiting for package file to be generated "
while true; do
	# Do remote SSH ls command
	PKG_FILE_INFO=$(ssh -i "$LOCAL_KEY_FILE" \
		-o "StrictHostKeyChecking=no" \
		-o "UserKnownHostsFile=/dev/null" \
		"$SSH_USER""@""$SSH_IP" "ls \"/tmp/""$LAMBDA_PKG_FILE""\" 2>/dev/null" 2>/dev/null)
	if [ "$PKG_FILE_INFO" == "/tmp/""$LAMBDA_PKG_FILE" ]; then
		echo " ""$PKG_FILE_INFO"
		break
	fi
	# A dummy tick dot
	for tick in $(seq 1 10); do
		echo -n "."
		sleep 1
	done
done

# Copy the LAMBDA_PKG_FILE to local
echo "Downloading package ..."
scp -i "$LOCAL_KEY_FILE" \
	-o "StrictHostKeyChecking=no" \
	-o "UserKnownHostsFile=/dev/null" \
	"$SSH_USER""@""$SSH_IP"":/tmp/""$LAMBDA_PKG_FILE" "$BUILD_DIR""/" 2>/dev/null

# Power off the instance
echo "Poweroff build instance."
ssh -i "$LOCAL_KEY_FILE" \
	-o "StrictHostKeyChecking=no" \
	-o "UserKnownHostsFile=/dev/null" \
	"$SSH_USER""@""$SSH_IP" "sudo poweroff" 2>/dev/null

# Run command to add extra files to the package
TMP_LOCAL_ADD_SCRIPT=$(mktemp)
echo "#!/usr/bin/env bash" > "$TMP_LOCAL_ADD_SCRIPT"
echo -n -e $ADD_CODE_CMD >> "$TMP_LOCAL_ADD_SCRIPT"
echo -n -e $ADD_EXT_FILES_CMD >> "$TMP_LOCAL_ADD_SCRIPT"
chmod +x "$TMP_LOCAL_ADD_SCRIPT"
$TMP_LOCAL_ADD_SCRIPT
rm -f "$TMP_LOCAL_ADD_SCRIPT"

# All done
echo "Package is ready at $BUILD_DIR/$LAMBDA_PKG_FILE"
echo "Done."

exit 0
