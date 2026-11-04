#!/bin/bash
set -e

cp /usr/local/bin/orca-entrypoint.sh /orca/entrypoint.sh
cp /usr/local/bin/orca-pairing-page.js /orca/pairing-page.js
cp /usr/local/bin/shared-runtime.sh /orca/runtime.sh
cp /usr/local/bin/shared-bashrc.sh /orca/bashrc.sh
# The volume can survive a restart. Copy contents into existing directories;
# copying the directories themselves would leave stale binaries at the top level.
for directory in runtime web cli bin skills; do
  mkdir -p "/orca/$directory"
  cp -r "/opt/orca/$directory/." "/orca/$directory/"
done
cp /opt/orca/LICENSE /orca/LICENSE

echo "Orca injector complete"
