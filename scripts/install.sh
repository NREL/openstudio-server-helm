#!/bin/bash
# When you want to test the template rendering, but not actually install anything, you can use

export OPENSTUDIO_VERSION=2.9.1
helm install openstudio-server-${OPENSTUDIO_VERSION} --debug ./openstudio-server
