#!/usr/bin/env python3
"""Build the pinned cmux-only TUI on CI; never install or run a model turn."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
from check import HERE, prepare_release_lock, run, test


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((HERE / 'source.json').read_text())
    if run(['git', 'rev-parse', 'HEAD'], source).strip() != manifest['commit']:
        raise RuntimeError('Wrong upstream source revision')
    if run(['git', 'status', '--porcelain'], source).strip():
        raise RuntimeError('A clean source checkout is required')
    prepare_release_lock(source, output)
    patches = ['regression-tests.patch', 'quiet-fullscreen.patch', 'attach-only.patch']
    for name in patches:
        run(['git', 'apply', '--check', str(HERE / name)], source)
        run(['git', 'apply', str(HERE / name)], source)
    root = source / 'codex-rs'
    command = ['cargo', 'test', '--locked', '-p', 'codex-tui', '--features', 'cmux-quiet']
    # Require executed tests, not a successful compilation or an unmatched filter.
    for target, selector, count in [('--lib', 'cmux_quiet_', 7), ('--lib', 'cmux_attach_', 2), ('--bin', 'cmux_attach_', 2)]:
        arguments = command + ([target, 'cmux-codex-quiet'] if target == '--bin' else [target])
        with (output / f'{target[2:]}-{selector}.log').open('w') as log:
            subprocess.run(arguments + [selector, '--', '--test-threads=1'], cwd=root, check=True, stdout=log, stderr=subprocess.STDOUT)
        text = (output / f'{target[2:]}-{selector}.log').read_text()
        if f'test result: ok. {count} passed; 0 failed; 0 ignored;' not in text:
            raise RuntimeError(f'Expected {count} executed {selector} tests')
    with (output / 'build.log').open('w') as log:
        subprocess.run(['cargo', 'build', '--locked', '--release', '-p', 'codex-tui', '--bin', 'cmux-codex-quiet', '--features', 'cmux-quiet'], cwd=root, check=True, stdout=log, stderr=subprocess.STDOUT)
    target = Path(os.environ.get('CARGO_TARGET_DIR', root / 'target')) / 'release' / 'cmux-codex-quiet'
    binary = output / 'cmux-codex-quiet'
    shutil.copy2(target, binary)
    if platform.system() == 'Darwin':
        subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
    payload = dict(manifest, platform=platform.system(), architecture=platform.machine(),
                   binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   patches={name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in patches},
                   cmux_commit=os.environ.get('GITHUB_SHA'), attach_only=True)
    (output / 'manifest.json').write_text(json.dumps(payload, indent=2) + '\n')
    for name in ['LICENSE', 'NOTICE']:
        if (source / name).exists(): shutil.copy2(source / name, output / name)
    print('Built and staged cmux-only frontend; no local installation or model request', flush=True)


if __name__ == '__main__': main()
