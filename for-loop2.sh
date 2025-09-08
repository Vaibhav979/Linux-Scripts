#!/bin/bash
#
<<comment
1 is for folder name
2 is for start range
3 is for end
comment

for (( num=$2; num<=$3; num++ ))
do
	mkdir "$1$num"
done
