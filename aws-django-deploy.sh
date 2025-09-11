#!/bin/bash
#
set -euo pipefail

# ----------------------------
# EC2 Infra Setup
# ----------------------------
#
check_awscli(){
	if ! command -v aws &> /dev/null; then
		echo "AWS cli is not installed. Spinning up the installation now...."
		return 1
	fi
}

install_awscli() {
	echo "Installing AWS cli v2....."
	curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    sudo apt-get install -y unzip &> /dev/null
    unzip -q awscliv2.zip
    sudo ./aws/install
    aws --version
    rm -rf awscliv2.zip ./aws
}

create_ec2_instance() {
	local ami_id="$1"
	local instance_type="$2"
	local key_name="$3"
	local subnet_id="$4"
	local security_group_ids="$5"
	local instance_name="$6"

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

	echo "$instance_id"

}

wait_for_instance() {
	local instance_id="$1"
	echo "Waiting for instance $instance_id to be in running state...." >&2

	aws ec2 wait instance-running --instance-ids "$instance_id"

	#getting public ip of ec2 machine
	public_ip=$(aws ec2 describe-instances \
		--instance-ids "$instance_id" \
		--query 'Reservations[0].Instances[0].PublicIpAddress' \
		--output text)

	echo "$public_ip"
}

#------------------------------
#Django App Deployment
#------------------------------
#
deploy_django() {
	local public_ip="$1"
	local key_name="$2"

	echo "Deploying Django App on $public_ip"

	# SSH into the instance
	# The << 'EOF' part means run the following block of commands on the remote server until EOF is reached
	ssh -o StrictHostKeyChecking=no -i "$key_name.pem" ubuntu@"$public_ip" << 'EOF'

	set -e
        echo "*************Deployment Started***************"

	if [ ! -d "django-notes-app" ]; then
            echo "Cloning the Django app..."
            git clone https://github.com/LondheShubham153/django-notes-app.git
	    cd django-notes-app
	else
            echo "Code directory already exists"
            cd django-notes-app
        fi

	echo "Installing Dependencies"
        sudo apt-get update -y
        sudo apt-get install -y docker.io nginx -y
        sudo chown $USER /var/run/docker.sock
        sudo systemctl enable docker
	sudo systemctl enable nginx
	sudo systemctl restart docker
	docker build -t notes-app .
	docker run -d -p 8000:8000 notes-app:latest gunicorn --bind 0.0.0.0:8000 django_notes_app.wsgi:application


EOF
    echo "🎉 Django app should be live at http://$public_ip:8000"

}

open_port_8000() {
    local security_group_id="$1"

    echo "🔓 Allowing inbound traffic on port 8000 in Security Group: $security_group_id"
    aws ec2 authorize-security-group-ingress \
        --group-id "$security_group_id" \
        --protocol tcp \
        --port 8000 \
        --cidr 0.0.0.0/0 || true
}

# =====================
# Main
# =====================
main(){
    if ! check_awscli; then
        install_awscli || exit 1
    fi

    echo "Creating EC2 instance..."
    AMI_ID="ami-0a716d3f3b16d290c"
    INSTANCE_TYPE="t3.micro"
    KEY_NAME="ssh-key"
    SUBNET_ID="subnet-0a7550ee1ba1eb834"
    SECURITY_GROUP_IDS="sg-0032b3d4efe1cf61f"
    INSTANCE_NAME="Shell-Script-EC2-Demo"

    instance_id=$(create_ec2_instance "$AMI_ID" "$INSTANCE_TYPE" "$KEY_NAME" "$SUBNET_ID" "$SECURITY_GROUP_IDS" "$INSTANCE_NAME")
    public_ip=$(wait_for_instance "$instance_id")

    # 🔓 Open port 8000 on the security group
    open_port_8000 "$SECURITY_GROUP_IDS"

    deploy_django "$public_ip" "$KEY_NAME"
}

main "$@"
