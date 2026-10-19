#!/bin/bash
set -e

cp /usr/local/bin/orca-entrypoint.sh /orca/entrypoint.sh
cp /usr/local/bin/orca-pairing-page.js /orca/pairing-page.js
cp /usr/local/bin/shared-runtime.sh /orca/runtime.sh
cp /usr/local/bin/shared-bashrc.sh /orca/bashrc.sh
cp -r /opt/orca/runtime /orca/runtime
cp -r /opt/orca/web /orca/web
cp -r /opt/orca/cli /orca/cli
cp -r /opt/orca/bin /orca/bin
cp -r /opt/orca/skills /orca/skills
cp /opt/orca/LICENSE /orca/LICENSE

echo "Orca injector complete"
