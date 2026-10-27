#!/usr/bin/env python3
"""Build the pinned cmux-only TUI on CI; never install or run a model turn."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import platform
import shutil
import subprocess
from check import HERE, orchestration_proof, prepare_release_lock, resume_compat_proof, run, tool_coverage_proof, working_tip_proof
import source_mtimes


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
    patches = manifest['patches']
    for name in patches:
        if name in ('focus-mode.patch', 'working-tip.patch', 'orchestration.patch',
                    'resume-compat-tests.patch', 'resume-compat.patch',
                    'tool-coverage-tests.patch', 'tool-coverage.patch'): continue
        run(['git', 'apply', '--check', str(HERE / name)], source)
        run(['git', 'apply', str(HERE / name)], source)
    root = source / 'codex-rs'

    def tests(target, selector, count, *, feature=True, should_fail=False, label=None):
        command = ['cargo', 'test', '--locked', '-p', 'codex-tui']
        if feature: command += ['--features', 'cmux-quiet']
        command += ['--bin', 'cmux-codex-quiet'] if target == 'bin' else ['--lib']
        log = output / f"{label or target + '-' + selector}.log"
        print(f"Running {label or selector}: {count} behavioral cases", flush=True)
        with log.open('w') as stream:
            outcome = subprocess.run(command + [selector, '--', '--test-threads=1'], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
        text = log.read_text()
        summaries = re.findall(r'test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;', text)
        if len(summaries) != 1:
            print(text[-6000:]); raise RuntimeError('Expected executed tests; compilation/setup failure is not a behavioral regression')
        state, passed, failed, ignored = summaries[0]
        if int(passed) + int(failed) != count or int(ignored):
            raise RuntimeError(f'Expected {count} executed tests: {summaries[0]}')
        valid = outcome.returncode != 0 and int(failed) > 0 if should_fail else outcome.returncode == 0 and int(failed) == 0
        if not valid:
            print(text[-6000:]); raise RuntimeError('Unexpected behavioral result')
        print(f"Observed {passed} passed / {failed} failed", flush=True)

    # A checkout gives unchanged local crates new timestamps. Reuse only
    # content-verified timestamps from this compiler cache, before any build.
    # Never restore again after mutating focus-before into focus-after.
    mtime_cache = Path(os.environ.get('CARGO_TARGET_DIR', root / 'target')) / '.cmux-source-mtimes.json'
    print(f'Restored {source_mtimes.restore(source, mtime_cache)} identical source timestamps', flush=True)
    try:
        tests('lib', 'cmux_quiet_', 7, feature=False)
        tests('lib', 'cmux_attach_', 3)
        tests('bin', 'cmux_attach_', 2)
        tests('lib', 'cmux_binding_', manifest['bindingTestCount'])
        tests('lib', 'cmux_focus_', manifest['focusTestCount'], should_fail=True, label='focus-before')
        run(['git', 'apply', '--check', str(HERE / 'focus-mode.patch')], source)
        run(['git', 'apply', str(HERE / 'focus-mode.patch')], source)
        tests('lib', 'cmux_focus_', manifest['focusTestCount'], label='focus-after')
        working_tip_proof(source, output, manifest)
        orchestration_proof(source, output, manifest)
        resume_compat_proof(source, output, manifest)
        tool_coverage_proof(source, output, manifest)
        print('Building the installable quiet frontend', flush=True)
        with (output / 'build.log').open('w') as log:
            outcome = subprocess.run(['cargo', 'build', '--locked', '--release', '-p', 'codex-tui', '--bin', 'cmux-codex-quiet', '--features', 'cmux-quiet'], cwd=root, stdout=log, stderr=subprocess.STDOUT)
        if outcome.returncode:
            print((output / 'build.log').read_text()[-6000:], flush=True)
            raise RuntimeError('Optimized frontend compilation failed; see build.log')
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
    finally:
        try:
            print(f'Recorded {source_mtimes.save(source, mtime_cache)} source timestamps for the next build', flush=True)
        except (OSError, subprocess.SubprocessError) as error:
            print(f'Source timestamp cache was not saved: {error}', flush=True)



if __name__ == '__main__': main()
