#!/bin/zsh
# Build installable disk images: build/Palladium-<version>-arm64.dmg (Apple silicon)
# and build/Palladium-<version>-x86_64.dmg (Intel). Pass architectures to build a subset.
set -eu
prototype_root="${0:A:h:h}"
cd "$prototype_root"
export CLANG_MODULE_CACHE_PATH="$prototype_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$prototype_root/.build/module-cache"
notes_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
(( $# )) || set -- arm64 x86_64
for notes_arch in "$@"; do
  swift build --build-system native --disable-sandbox -c release --arch "$notes_arch" --scratch-path ".build-dmg-$notes_arch" --cache-path .build/cache --config-path .build/config --security-path .build/security --product Notes -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$notes_sdk_version"
  python3 - "$notes_arch" <<'PY'
from pathlib import Path
import plistlib,shutil,tempfile,subprocess,sys
arch=sys.argv[1]; root=Path.cwd(); stage=Path(tempfile.mkdtemp(prefix='palladium-dmg-stage-'))
try:
    products=Path(subprocess.run(['swift','build','--build-system','native','-c','release','--arch',arch,'--scratch-path',f'.build-dmg-{arch}','--show-bin-path'],check=True,capture_output=True,text=True).stdout.strip())
    app=stage/'Palladium.app'; executable=app/'Contents/MacOS/Notes'
    executable.parent.mkdir(parents=True)
    shutil.copyfile(products/'Notes',executable);executable.chmod(0o755)
    shutil.copytree(root/'Resources', app/'Contents/Resources', dirs_exist_ok=True, ignore=shutil.ignore_patterns('Branding'))
    for bundle in products.glob('*.bundle'):
        shutil.copytree(bundle, app/'Contents/Resources'/bundle.name, dirs_exist_ok=True)
    shutil.copyfile(root/'Resources/Branding/Palladium.icns', app/'Contents/Resources/Palladium.icns')
    shutil.copyfile(root/'Resources/Branding/PalladiumMark.png', app/'Contents/Resources/PalladiumMark.png')
    version='0.3.0'
    # No PrototypeWorkspace: an installed app creates its workspace in Application Support.
    info={"CFBundleExecutable":"Notes","CFBundleIdentifier":"local.biel.DerechoReplayPrototype","CFBundleName":"Palladium","CFBundleDisplayName":"Palladium","CFBundleIconFile":"Palladium.icns","CFBundlePackageType":"APPL","CFBundleShortVersionString":version,"CFBundleVersion":"3","LSMinimumSystemVersion":"14.0","NSHighResolutionCapable":True,"NSMicrophoneUsageDescription":"Dictar en el cuadro de mensaje únicamente cuando pulses el micrófono. El modelo local funciona en este Mac; la opción API envía audio a OpenAI."}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    for file in app.rglob('*'):
        if file.is_file(): file.chmod(file.stat().st_mode | 0o200)
    subprocess.run(['xattr','-cr',str(app)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    (stage/'Applications').symlink_to('/Applications')
    (root/'build').mkdir(exist_ok=True)
    image=root/f'build/Palladium-{version}-{arch}.dmg'
    subprocess.run(['hdiutil','create','-volname','Palladium','-srcfolder',str(stage),'-fs','HFS+','-format','UDZO','-ov',str(image)],check=True,capture_output=True)
    subprocess.run(['hdiutil','verify',str(image)],check=True,capture_output=True)
    print(image)
finally:shutil.rmtree(stage)
PY
done
