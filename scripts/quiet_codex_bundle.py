"""Validate a pinned quiet frontend artifact before copying it into a staged app."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'experiments/codex-quiet'


def validate_artifact(artifact: Path, proof: Path = PROOF) -> Path:
    expected = json.loads((proof / 'source.json').read_text())
    manifest_path = artifact / 'manifest.json'
    binary = artifact / 'cmux-codex-quiet'
    for file in [manifest_path, binary, artifact / 'LICENSE']:
        if not file.is_file() or file.is_symlink():
            raise ValueError(f'Missing or linked artifact file: {file.name}')
    manifest = json.loads(manifest_path.read_text())
    for key in ['commit', 'release', 'repository']:
        if manifest.get(key) != expected[key]:
            raise ValueError(f'Quiet frontend source mismatch: {key}')
    if (manifest.get('attach_only') is not True or manifest.get('platform') != 'Darwin'
            or manifest.get('architecture') not in ['arm64', 'aarch64']):
        raise ValueError('Expected an attach-only macOS arm64 frontend')
    expected_patches = {name: hashlib.sha256((proof / name).read_bytes()).hexdigest()
                        for name in expected['patches']}
    if manifest.get('patches') != expected_patches:
        raise ValueError('Quiet frontend patch provenance mismatch')
    if manifest.get('binary_sha256') != hashlib.sha256(binary.read_bytes()).hexdigest():
        raise ValueError('Quiet frontend binary checksum mismatch')
    return binary


def verify_macos_binary(binary: Path) -> None:
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if architectures != ['arm64']:
        raise ValueError('Quiet frontend is not a native arm64 Mach-O binary')
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)


def stage_artifact(artifact: Path, resources: Path, verify_binary=verify_macos_binary) -> None:
    binary = validate_artifact(artifact)
    verify_binary(binary)
    destination = resources / 'bin' / 'cmux-codex-quiet'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary, destination)
    destination.chmod(0o755)
    licenses = resources / 'licenses' / 'codex-quiet'
    licenses.mkdir(parents=True, exist_ok=True)
    for name in ['LICENSE', 'NOTICE', 'manifest.json']:
        source = artifact / name
        if source.is_file() and not source.is_symlink():
            shutil.copyfile(source, licenses / name)
