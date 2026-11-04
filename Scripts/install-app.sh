#!/bin/bash
# Build Lock In from source and install it to /Applications. See Scripts/install.sh,
# which also links the `lockin` CLI. The build is moved there: dist/ won't hold it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build-app.sh
exec bash Scripts/install.sh "dist/Lock In.app"
