#!/bin/bash

<<comment

adding a new user in system
comment

read -p "Enter the user to be added: " username

echo "You entered, $username"

sudo useradd -m $username

echo "New user added"
