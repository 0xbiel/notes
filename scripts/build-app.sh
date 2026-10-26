#!/bin/zsh
set -eu
prototype_root="${0:A:h:h}"
cd "$prototype_root"
export CLANG_MODULE_CACHE_PATH="$prototype_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$prototype_root/.build/module-cache"
# Record the actual build SDK so macOS enables its current native control design.
notes_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build --build-system native --disable-sandbox --scratch-path .build-native --cache-path .build/cache --config-path .build/config --security-path .build/security --product Notes -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$notes_sdk_version"
notes_workspace="${1:-${NOTES_WORKSPACE:-$prototype_root}}"
python3 - "$notes_workspace" <<'PY'
from pathlib import Path
import os,plistlib,shutil,tempfile,subprocess,sys
sys.path.insert(0, str(Path.cwd()/'scripts'))
from release_version import metadata
release_metadata=metadata()
root=Path.cwd(); stage=Path(tempfile.mkdtemp(prefix='derecho-build-stage-'))
try:
    workspace=Path(sys.argv[1]).absolute()
    if not (workspace/'original-hashes.json').is_file():raise RuntimeError('Initialize a separate demo workspace or supply NOTES_WORKSPACE before packaging')
    app=stage/'Palladium.app'; executable=app/'Contents/MacOS/Notes'
    executable.parent.mkdir(parents=True)
    shutil.copyfile(root/'.build-native/debug/Notes',executable);executable.chmod(0o755)
    shutil.copytree(root/'Resources', app/'Contents/Resources', dirs_exist_ok=True, ignore=shutil.ignore_patterns('Branding'))
    for bundle in (root/'.build-native/debug').glob('*.bundle'):
        shutil.copytree(bundle, app/'Contents/Resources'/bundle.name, dirs_exist_ok=True)
    shutil.copyfile(root/'Resources/Branding/Palladium.icns', app/'Contents/Resources/Palladium.icns')
    shutil.copyfile(root/'Resources/Branding/PalladiumMark.png', app/'Contents/Resources/PalladiumMark.png')
    info={"CFBundleExecutable":"Notes","CFBundleIdentifier":"local.biel.DerechoReplayPrototype","CFBundleName":"Palladium","CFBundleDisplayName":"Palladium","CFBundleIconFile":"Palladium.icns","CFBundlePackageType":"APPL","CFBundleShortVersionString":release_metadata["version"],"CFBundleVersion":release_metadata["build"],"LSMinimumSystemVersion":"14.0","NSHighResolutionCapable":True,"NSMicrophoneUsageDescription":"Dictar en el cuadro de mensaje únicamente cuando pulses el micrófono. El modelo local funciona en este Mac; la opción API envía audio a OpenAI.","PrototypeWorkspace":str(workspace)}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # SwiftPM resources can arrive read-only; make staged copies writable for signing cleanup.
    for file in app.rglob('*'):
        if file.is_file(): file.chmod(file.stat().st_mode | 0o200)
    subprocess.run(['xattr','-cr',str(app)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    destination=root/'build/Palladium.app'
    if destination.is_symlink():raise RuntimeError('Generated app path must not be a symlink')
    destination.parent.mkdir(exist_ok=True)
    # Replace file inodes instead of overwriting a mapped executable. Overwriting
    # can leave macOS with stale signed pages and cause CODESIGNING Invalid Page.
    def replace_file(source, target):
        fd, temporary = tempfile.mkstemp(prefix='.notes-build-', dir=Path(target).parent)
        os.close(fd)
        try:
            shutil.copyfile(source, temporary)
            shutil.copymode(source, temporary)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        return target
    shutil.copytree(app,destination,dirs_exist_ok=True,copy_function=replace_file)
    subprocess.run(['codesign','--verify','--deep',str(destination)],check=True)
    print(destination)
finally:shutil.rmtree(stage)
PY
