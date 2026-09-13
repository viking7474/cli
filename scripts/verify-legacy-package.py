#!/usr/bin/env python3
"""Verify the experimental iOS 13 rootful package and binary invariants."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tarfile

root = Path(__file__).resolve().parents[1]
binary = root / '.build/icli-ios13'
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
package = root / f'.build/com.icli.icli_{version}_iphoneos-arm-ios13.deb'
extracted = root / '.build/package-check/rootful-ios13/usr/bin/icli'

digest = hashlib.sha256(binary.read_bytes()).hexdigest()
entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(binary)]))
assert entitlements == plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
assert 'platform IOS' in build and 'minos 13.0' in build, build
loads = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
for load in loads:
    name = load.strip().split(' (')[0]
    assert name.startswith(('/System/Library/', '/usr/lib/')), name
    assert 'libarchive' not in name, 'libarchive must be statically linked'

undefined = subprocess.check_output(['nm', '-u', str(binary)], text=True)
newer_libxpc_imports = [
    '__xpc_pipe_interface_routine',
    '_xpc_user_sessions_get_foreground_uid',
    '_xpc_shmem_create',
    '__os_alloc_once_table',
]
strong_newer_libxpc = [symbol for symbol in newer_libxpc_imports if symbol in undefined]
assert not strong_newer_libxpc, 'legacy binary strongly imports newer libxpc symbols: ' + ', '.join(strong_newer_libxpc)

assert hashlib.sha256(extracted.read_bytes()).hexdigest() == digest
assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Architecture'], text=True).strip() == 'iphoneos-arm'
assert subprocess.check_output(['dpkg-deb', '-f', str(package), 'Version'], text=True).strip() == version
dependency = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Depends'], text=True).strip()
assert dependency == 'firmware (>= 13.0)', dependency
archive = subprocess.check_output(['dpkg-deb', '--fsys-tarfile', str(package)])
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    members = tar.getmembers()
    assert all(member.uid == 0 and member.gid == 0 for member in members)
    executables = [member for member in members if member.isfile() and member.mode & 0o111]
    assert len(executables) == 1 and executables[0].name.endswith('/usr/bin/icli'), executables

report = {
    'version': version,
    'profile': 'ios13-rootful',
    'binary_sha256': digest,
    'architecture': 'arm64',
    'minimum_ios': '13.0',
    'package_architecture': 'iphoneos-arm',
    'system_loads': loads,
    'strong_newer_libxpc_imports': strong_newer_libxpc,
    'packages': [{
        'layout': 'rootful',
        'file': package.name,
        'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
        'depends': dependency,
        'single_binary': True,
        'root_owned': True,
    }],
}
report.update(runpy.run_path(str(root / 'scripts/verify-binary.py'))['verify_no_process_imports'](binary))
(root / '.build/package-verification-ios13.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS iOS 13 rootful package architecture, minOS, metadata, entitlements, ownership and imports')
