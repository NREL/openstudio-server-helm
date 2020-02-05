#!/bin/bash
# When you want to test the template rendering, but not actually install anything, you can use

kubectl delete deployment web web-background rserve
sleep 5
helm uninstall openstudio-server --debug
