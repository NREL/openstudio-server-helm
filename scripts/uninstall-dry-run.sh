#!/bin/bash
# When you want to test the template rendering, but not actually install anything, you can use

helm uninstall openstudio-server --debug --dry-run
