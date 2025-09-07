#!/bin/bash
#
<< comment 
Implementing if conditional
comment

read -p "Enter your age: " age

if [[ $age == 18 ]];
then
	echo "You can vote"
elif [[ $age > 18 ]];
then 
	echo "You can vote"
else
	echo "you cannot vote"
fi
