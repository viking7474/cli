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
runtime_manifest_path = root / '.build/swift-runtime-ios13.json'

digest = hashlib.sha256(binary.read_bytes()).hexdigest()
entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(binary)]))
assert entitlements == plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
assert 'platform IOS' in build and 'minos 13.0' in build, build

load_lines = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
loads = [line.strip().split(' (')[0] for line in load_lines]
for name in loads:
    allowed = name.startswith(('/System/Library/', '/usr/lib/')) or (
        name.startswith('@rpath/libswift') and name.endswith('.dylib')
    )
    assert allowed, f'unexpected dynamic dependency: {name}'
    assert 'libarchive' not in name, 'libarchive must be statically linked'

assert runtime_manifest_path.is_file(), 'legacy Swift runtime manifest missing'
runtime = json.loads(runtime_manifest_path.read_text())
assert runtime['minimum_ios'] == '13.0', runtime
assert '@executable_path/../lib/icli' in runtime['rpaths'] or not runtime['bundled'], runtime['rpaths']
referenced_swift = set(runtime['referenced_swift_rpath_libraries'])
bundled_by_name = {item['name']: item for item in runtime['bundled']}
if 'libswift_Concurrency.dylib' in referenced_swift:
    assert 'libswift_Concurrency.dylib' in bundled_by_name, (
        'iOS 13/14 do not ship libswift_Concurrency; the back-deployment dylib must be bundled'
    )

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
    by_name = {member.name.removeprefix('./'): member for member in members}
    expected_executables = {'usr/bin/icli'} | {
        metadata['file'].lstrip('/') for metadata in bundled_by_name.values()
    }
    executable_paths = {
        member.name.removeprefix('./')
        for member in members
        if member.isfile() and member.mode & 0o111
    }
    assert executable_paths == expected_executables, (executable_paths, expected_executables)
    for name, metadata in bundled_by_name.items():
        relative = metadata['file'].lstrip('/')
        assert relative in by_name, f'packaged Swift runtime missing: {relative}'
        member = by_name[relative]
        stream = tar.extractfile(member)
        assert stream is not None, relative
        packaged_digest = hashlib.sha256(stream.read()).hexdigest()
        assert packaged_digest == metadata['sha256'], f'Swift runtime hash mismatch: {name}'

report = {
    'version': version,
    'profile': 'ios13-rootful',
    'binary_sha256': digest,
    'architecture': 'arm64',
    'minimum_ios': '13.0',
    'package_architecture': 'iphoneos-arm',
    'system_loads': load_lines,
    'swift_runtime': runtime,
    'strong_newer_libxpc_imports': strong_newer_libxpc,
    'packages': [{
        'layout': 'rootful',
        'file': package.name,
        'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
        'depends': dependency,
        'single_cli_executable': True,
        'bundled_swift_runtime': sorted(bundled_by_name),
        'root_owned': True,
    }],
}
report.update(runpy.run_path(str(root / 'scripts/verify-binary.py'))['verify_no_process_imports'](binary))
(root / '.build/package-verification-ios13.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS iOS 13 rootful package architecture, minOS, Swift back-deployment runtime, metadata, entitlements, ownership and imports')
