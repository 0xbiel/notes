#!/bin/zsh
set -eu
prototype_root="${0:A:h:h}"
if [[ ! -d "$prototype_root/build/Notes.app" ]]; then
  zsh "$prototype_root/scripts/build-app.sh"
fi
open "$prototype_root/build/Notes.app"
