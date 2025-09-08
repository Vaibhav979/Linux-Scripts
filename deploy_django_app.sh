#!/bin/bash
#
<<comment
deploy django app
comment

code_clone() {
	echo "CLoning the Django app.."
	git clone https://github.com/LondheShubham153/django-notes-app.git
}

install_requirements() {
	echo "Installing Dependencies"
	sudo apt-get update -y
	sudo apt-get install docker-ce docker-ce-cli containerd.io nginx -y
}

required_restarts() {
	sudo chown $USER /var/run/docker.sock
	sudo systemctl enable docker
	sudo systemctl enable nginx
	sudo systemctl restart docker
}

deploy() {
	docker build -t notes-app .
	docker run -d -p 8000:8000 notes-app:latest
}

echo "*************Deployment Started***************"
if ! code_clone; then
	echo "Code directory already exists"
	cd django-notes-app
fi

if ! install_requirements; then
	echo "Installation Failed"
	exit 1
fi

if ! required_restarts; then
	echo "System fault identified"
	exit 1
fi
deploy
echo "*************Deployed***************"

