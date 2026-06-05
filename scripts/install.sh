#!/bin/bash
# When you want to test the template rendering, but not actually install anything, you can use

helm install openstudio-server --debug ./openstudio-server --set global.provider.name=aws
