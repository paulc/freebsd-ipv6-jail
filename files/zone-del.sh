#!/bin/sh

usage="$0: <name>"

printf 'zone-begin shell.pchak.net\nzone-unset -- %s\nzone-diff --\nzone-commit --\n' ${1?$usage} | knotc
