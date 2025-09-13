#!/bin/bash
set -euo pipefail

STATE_FILE="ec2_state.json" # lightweight 'state file' for tracking instances

# --------------------
# Utility Functions
# --------------------

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

init_state() {
	# initialises the 'state file' if it doesn't exist
	# an attempt at persisting infra state like terraform
	if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" &>/dev/null; then
	 	echo "Initializing fresh state file..."
        	echo '{"instances":[]}' > "$STATE_FILE"
	fi
}

reconcile_state() {
    echo "Reconciling state file with actual AWS EC2 instances..."

    # Get all actual instance IDs in AWS
    aws_ids=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output json)

    # Remove instances from state file if they no longer exist
    tmp_file=$(mktemp)
    jq --argjson aws_ids "$aws_ids" \
       '.instances |= map(select(.InstanceId as $id | $aws_ids | index($id)))' \
       "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
}


# -------------------
# EC2 FUNCTIONS
# -------------------

create_ec2_instance() {
    local ami_id="$1"
    local instance_type="$2"
    local key_name="$3"
    local subnet_id="$4"
    local security_group_ids="$5"
    local instance_name="$6"

    # ---------------------------------------
    # Attempt at state management:
    # checking if an instance with this name already exists in the state file i.e is preserved
    # preventing recreating the same instances (idempotency concept )
    # ---------------------------------------
    
    instance_entry=$(jq -r --arg name "$instance_name" '.instances[] | select(.Name==$name) | .InstanceId' "$STATE_FILE")

    # Opens my local state file (a JSON file tracking EC2 instances).Uses jq to look inside .instances[] array. Filters for the object where .Name == instance_name. Stores that JSON object (if found) into instance_entry.

    
	if [[ -n "$instance_entry" ]]; then
	    # Instance exixts: check for drift
	    # Reads the InstanceId field from the JSON stored in instance_entry
	    id=$(jq -r '.InstanceId' <<< "instance-entry")
	    state=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated") 
	   # Calls AWS CLI to fetch the real current state of that instance from AWS
	   # This is drift detection: compare the local state file with AWS’s actual state. If AWS says the instance is gone (or stopped), I can reconcile.
	   #
	   if [[ "$state" == "terminated" ]]; then
		   echo "Previous instance $instance_name was terminated. Removing from state..."
		   jq --arg id "$id" '(.instances[] | select(.InstanceId==$id)) |= empty' "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"

		   #If the instance is not terminated, fetch its InstanceType
	   else
		   actual_type=$(aws ec2 describe-instances --instance-ids "id" \
			   --query 'Reservations[0].Instances[0].InstanceType' --output text)

	if [[ "$actual_type" != "$instance_type" ]]; then
	    echo "Instance $instance_name exists but type differs. Consider modifying or recreating."
    # Optionally modify or terminate/recreate here
	fi


	fi
            echo "Instance $instance_name already exists (ID: $id). Skipping creation..."
            wait_for_instance "$id"
            return
        fi


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

    # Add full attributes to state (Terraform-style)
    jq --arg name "$instance_name" \
       --arg id "$instance_id" \
       --arg type "$instance_type" \
       --arg ami "$ami_id" \
       --arg key "$key_name" \
       --arg subnet "$subnet_id" \
       --argjson sg_ids "[$(echo $security_group_ids | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]}" \
       '.instances += [{"Name":$name,"InstanceId":$id,"Status":"pending","InstanceType":$type,"AMI_ID":$ami,"KeyName":$key,"SubnetId":$subnet,"SecurityGroupIds":$sg_ids}]' \
       "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"

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
	    # Updating the state file with the current status
	    jq --arg id "$instance_id" --arg status "$state" \
               '(.instances[] | select(.InstanceId==$id) | .Status) = $status' "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
            break
        fi
        sleep 10
    done
}

list_instances() {
    # Pretty-print all instances tracked in our "state file"
    echo "Current instances in state:"
    jq -r '.instances[] | "\(.Name) -> \(.InstanceId) (\(.Status))"' "$STATE_FILE"
}

delete_instance() {
	local instance_name="$1"

	# looking instance id from state file
	instance_id=$(jq -r --arg name "$instance_name" '.instance[] | select(.Name==$name) | .InstanceId' "$STATE_FILE")

	if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
		echo "No instance found with name $instance_name in state."
        return
    fi

    echo "Terminating instance $instance_name (ID: $instance_id)..."
    aws ec2 terminate-instances --instance-ids "$instance_id" &> /dev/null

    # Wait until terminated and remove from state
    while true; do
        state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
        if [[ "$state" == "terminated" ]]; then
            echo "Instance $instance_name terminated."
            # Remove from state file
            jq --arg id "$instance_id" '(.instances[] | select(.InstanceId==$id)) |= empty' "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
            break
        fi
        sleep 5
    done
}

check_drift() {
    for instance in $(jq -c '.instances[]' "$STATE_FILE"); do
        id=$(jq -r '.InstanceId' <<< "$instance")
        desired_type=$(jq -r '.InstanceType' <<< "$instance")
        actual_type=$(aws ec2 describe-instances --instance-ids "$id" \
            --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo "terminated")

        if [[ "$actual_type" == "terminated" ]]; then
            echo "Instance $id terminated manually. Removing from state."
            jq --arg id "$id" '(.instances[] | select(.InstanceId==$id)) |= empty' "$STATE_FILE" > tmp.json && mv tmp.json "$STATE_FILE"
        elif [[ "$actual_type" != "$desired_type" ]]; then
            echo "Drift detected on $id! Desired: $desired_type, Actual: $actual_type"
            # Optional: you could terminate & recreate or modify in-place here
        fi
    done
}

# -----------------------------------
# Main
# -----------------------------------


main(){
	if ! check_awscli;
	then 
		install_awscli || exit 1
	fi
	init_state
	reconcile_state #  Sync state with actual AWS before anything
	check_drift # Detect attribute drift (manual fix or future enhancement)
	echo "Creating EC2 instance..."

	#Specify the parameters for creating the EC2 instance
	AMI_ID="ami-0a716d3f3b16d290c"
	INSTANCE_TYPE="t3.micro"
	KEY_NAME="ssh-key"
	SUBNET_ID="subnet-0a7550ee1ba1eb834"
	SECURITY_GROUP_IDS="sg-0032b3d4efe1cf61f"
	INSTANCE_NAME="Shell-Script-EC2-Demo"

	create_ec2_instance "$AMI_ID" "$INSTANCE_TYPE" "$KEY_NAME" "$SUBNET_ID" "$SECURITY_GROUP_IDS" "$INSTANCE_NAME"

	list_instances

	echo "EC2 instance creation completed."
}

main "$@"
