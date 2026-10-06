#!/bin/bash
set -e

cp /usr/local/bin/orca-entrypoint.sh /orca/entrypoint.sh
cp /usr/local/bin/shared-runtime.sh /orca/runtime.sh
cp /usr/local/bin/shared-bashrc.sh /orca/bashrc.sh
cp /usr/local/bin/shared-discover-models.sh /orca/discover-models.sh
cp -r /opt/orca/runtime /orca/runtime
cp -r /opt/orca/web /orca/web
cp /opt/orca/LICENSE /orca/LICENSE
cp -r /opt/app-root/src/.npm-global /orca/npm-global
cp -r /usr/lib/google-cloud-sdk /orca/google-cloud-sdk

echo "Orca injector complete"
