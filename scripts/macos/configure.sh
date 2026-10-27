#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSET="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ASSET"
python3 - "$ASSET" "$ROOT/assets/app_icon.png" <<'PY'
import json, pathlib, subprocess, sys
folder, source = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
images=[]
for size, scale in spec:
    px=size*scale
    name=f'icon_{size}_{scale}x.png'
    subprocess.run(['sips','-z',str(px),str(px),str(source),'--out',str(folder/name)],check=True,stdout=subprocess.DEVNULL)
    images.append({'filename':name,'idiom':'mac','scale':f'{scale}x','size':f'{size}x{size}'})
(folder/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
for old in folder.glob('app_icon*.png'):
    old.unlink()
PY
# Register .sprk files to preserve the existing macOS open-with behavior.
python3 - "$ROOT/macos/Runner/Info.plist" <<'PY'
import pathlib, plistlib, sys
p=pathlib.Path(sys.argv[1])
with p.open('rb') as f: data=plistlib.load(f)
data['CFBundleDisplayName']='SuperRackTools'
data['CFBundleName']='SuperRackTools'
doc={'CFBundleTypeExtensions':['sprk'],'CFBundleTypeName':'Waves SuperRack Session','CFBundleTypeRole':'Editor','LSItemContentTypes':['com.waves.superrack-session']}
data['CFBundleDocumentTypes']=[d for d in data.get('CFBundleDocumentTypes',[]) if 'com.waves.superrack-session' not in d.get('LSItemContentTypes',[])] + [doc]
uti={'UTTypeConformsTo':['public.database'],'UTTypeDescription':'Waves SuperRack Session','UTTypeIdentifier':'com.waves.superrack-session','UTTypeTagSpecification':{'public.filename-extension':['sprk']}}
data['UTImportedTypeDeclarations']=[d for d in data.get('UTImportedTypeDeclarations',[]) if d.get('UTTypeIdentifier')!='com.waves.superrack-session']+[uti]
with p.open('wb') as f: plistlib.dump(data,f,sort_keys=False)
PY
# Keep the app named SuperRackTools and support Monterey and later.
python3 - "$ROOT/macos/Runner.xcodeproj/project.pbxproj" <<'PY'
import pathlib, re, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
s=re.sub(r'MACOSX_DEPLOYMENT_TARGET = [^;]+;', 'MACOSX_DEPLOYMENT_TARGET = 12.0;', s)
s=s.replace('PRODUCT_NAME = "$(TARGET_NAME)";', 'PRODUCT_NAME = SuperRackTools;')
s=s.replace('com.example.superRackTools', 'tech.rslive.superracktools')
s=s.replace('super_rack_tools.app', 'SuperRackTools.app').replace('super_rack_tools', 'SuperRackTools')
p.write_text(s)
project_dir=p.parent.parent
app_info=project_dir/'Runner/Configs/AppInfo.xcconfig'
config=(app_info.read_text()
        .replace('PRODUCT_NAME = super_rack_tools','PRODUCT_NAME = SuperRackTools')
        .replace('com.example.superRackTools','tech.rslive.superracktools')
        .replace('com.example. All rights reserved.','tech.rslive. All rights reserved.'))
app_info.write_text(config)
scheme=p.parent/'xcshareddata/xcschemes/Runner.xcscheme'
scheme.write_text(scheme.read_text().replace('super_rack_tools.app','SuperRackTools.app').replace('super_rack_tools','SuperRackTools'))
PY
