#!/bin/bash
set -euo pipefail

check_awscli() {
    if ! command -v aws &> /dev/null; then
        echo "AWS CLI is not installed. Please install it first." >&2
	return 1
    fi
}

install_awscli() {
    echo "Installing AWS CLI v2 on Linux..."

    # Download and install AWS CLI v2
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    sudo apt-get install -y unzip &> /dev/null
    unzip -q awscliv2.zip
    sudo ./aws/install

    # Verify installation
    aws --version

    # Clean up
    rm -rf awscliv2.
}

create_ec2_instance() {
    local ami_id="$1"
    local instance_type="$2"
    local key_name="$3"
    local subnet_id="$4"
    local security_group_ids="$5"
    local instance_name="$6"

    # Run AWS CLI command to create EC2 instance
    instance_id=$(aws ec2 run-instances \
        --image-id "$ami_id" \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --subnet-id "$subnet_id" \
        --security-group-ids "$security_group_ids" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance_name}]" \
        --query 'Instances[0].InstanceId' \
        --output text
    )

    if [[ -z "$instance_id" ]]; then
        echo "Failed to create EC2 instance." >&2
        exit 1
    fi

    echo "Instance $instance_id created successfully."

    # Wait for the instance to be in running state
    wait_for_instance "$instance_id"
}

wait_for_instance() {
    local instance_id="$1"
    echo "Waiting for instance $instance_id to be in running state..."

    while true; do
        state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text)
        if [[ "$state" == "running" ]]; then
            echo "Instance $instance_id is now running."
            break
        fi
        sleep 10
    done
}

main(){
	if ! check_awscli;
	then 
		install_awscli || exit 1
	fi
	echo "Creating EC2 instance..."

	#Specify the parameters for creating the EC2 instance
	AMI_ID="ami-0a716d3f3b16d290c"
	INSTANCE_TYPE="t3.micro"
	KEY_NAME="ssh-key"
	SUBNET_ID="subnet-0a7550ee1ba1eb834"
	SECURITY_GROUP_IDS="sg-0032b3d4efe1cf61f"
	INSTANCE_NAME="Shell-Script-EC2-Demo"

	create_ec2_instance "$AMI_ID" "$INSTANCE_TYPE" "$KEY_NAME" "$SUBNET_ID" "$SECURITY_GROUP_IDS" "$INSTANCE_NAME"

	echo "EC2 instance creation completed."
}

main "$@"
