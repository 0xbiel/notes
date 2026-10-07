#!/bin/zsh
set -eu
prototype_root="${0:A:h:h}"
cd "$prototype_root"
export CLANG_MODULE_CACHE_PATH="$prototype_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$prototype_root/.build/module-cache"
swift build --build-system native --disable-sandbox --scratch-path .build-native --cache-path .build/cache --config-path .build/config --security-path .build/security --product Notes
notes_workspace="${1:-${NOTES_WORKSPACE:-$prototype_root}}"
python3 - "$notes_workspace" <<'PY'
from pathlib import Path
import plistlib,shutil,tempfile,subprocess,sys
root=Path.cwd(); stage=Path(tempfile.mkdtemp(prefix='derecho-build-stage-'))
try:
    workspace=Path(sys.argv[1]).absolute()
    if not (workspace/'original-hashes.json').is_file():raise RuntimeError('Initialize a separate demo workspace or supply NOTES_WORKSPACE before packaging')
    app=stage/'Notes.app'; executable=app/'Contents/MacOS/Notes'
    executable.parent.mkdir(parents=True)
    shutil.copyfile(root/'.build-native/debug/Notes',executable);executable.chmod(0o755)
    info={"CFBundleExecutable":"Notes","CFBundleIdentifier":"local.biel.DerechoReplayPrototype","CFBundleName":"Notes","CFBundleDisplayName":"Notes","CFBundlePackageType":"APPL","CFBundleShortVersionString":"0.3.0","CFBundleVersion":"3","LSMinimumSystemVersion":"14.0","NSHighResolutionCapable":True,"NSMicrophoneUsageDescription":"Grabar la clase únicamente cuando pulses Grabar; el audio permanece en este Mac.","PrototypeWorkspace":str(workspace)}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['xattr','-cr',str(app)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    destination=root/'build/Notes.app'
    if destination.is_symlink():raise RuntimeError('Generated app path must not be a symlink')
    destination.parent.mkdir(exist_ok=True)
    # Copy signed generated files only; preserve the active process and all notes.
    shutil.copytree(app,destination,dirs_exist_ok=True,copy_function=shutil.copyfile)
    (destination/'Contents/MacOS/Notes').chmod(0o755)
    subprocess.run(['codesign','--verify','--deep',str(destination)],check=True)
    print(destination)
finally:shutil.rmtree(stage)
PY
