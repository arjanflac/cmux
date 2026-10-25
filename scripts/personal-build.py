#!/usr/bin/env python3
"""Build cmux+ through the repository wrapper, with bounded compiler concurrency."""
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time

root = Path(__file__).resolve().parent.parent
tools = Path.home() / 'Library/Caches/cmux-personal-tools'
tools.mkdir(parents=True, exist_ok=True)
swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
zig = shutil.which('zig')
if not zig:
    sys.exit('zig must be installed at the version required by ghostty/build.zig.zon')
compiler = '#!/bin/sh\ncase " $* " in\n *" -frontend "*|*" -package-description-version "*) exec ' + shlex.quote(swift) + ' "$@" ;;\n *) exec ' + shlex.quote(swift) + ' "$@" -enable-batch-mode -driver-batch-count 256 -j1 ;;\nesac\n'
selector = 'SWIFT_EXEC=$(CMUX_PERSONAL_SWIFT_EXEC_$(TARGET_NAME):default=' + swift + ')'
# CI does not need IDE indexing. Keep the workstation's existing behavior and
# single-worker memory limits, and print timings so cache gains can be measured.
ci_options = ' -showBuildTimingSummary COMPILER_INDEX_STORE_ENABLE=NO' if os.environ.get('GITHUB_ACTIONS') == 'true' else ''
xcode = '#!/bin/sh\ncase " $* " in\n *" -project cmux.xcodeproj "*) exec /usr/bin/xcodebuild -jobs 1 "$@" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 SWIFT_COMPILATION_MODE=incremental SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=1 ' + shlex.quote(selector) + ' ' + shlex.quote('CMUX_PERSONAL_SWIFT_EXEC_cmux=' + str(tools / 'swiftc')) + ci_options + ' ;;\n *) exec /usr/bin/xcodebuild "$@" ;;\nesac\n'
for name, content in [('swiftc', compiler), ('xcodebuild', xcode)]:
    path = tools / name
    if not path.exists() or path.read_text() != content:
        path.write_text(content)
    path.chmod(0o755)
# A native launcher preserves Zig's executable-based discovery while limiting build workers.
launcher = tools / 'zig-low-memory.c'
launcher.write_text('#include <unistd.h>\n#include <stdlib.h>\n#include <string.h>\nint main(int n,char **v){char **a=calloc(n+2,sizeof(char*));if(!a)return 127;for(int i=0;i<n;i++)a[i]=v[i];a[0]=' + json.dumps(zig) + ';if(n>1&&!strcmp(v[1],"build"))a[n]="-j1";execv(a[0],a);return 127;}\n')
subprocess.run(['xcrun', 'clang', '-Os', str(launcher), '-o', str(tools / 'zig')], check=True)
env = os.environ.copy()
env.update(PATH=str(tools) + ':' + str(Path.home() / '.cargo/bin') + ':' + env.get('PATH', ''),
           CARGO_BUILD_JOBS='1', CMUX_ZIG=str(tools / 'zig'),
           CMUX_XCODEBUILD_LOCK_CONCURRENCY='1', CMUX_DEV_BACKEND_MODE='local',
           CMUX_GHOSTTYKIT_PREPROVISIONED='1', CMUX_RELOAD_NO_GLOBAL_CLI_LINKS='1')
if not (root / 'GhosttyKit.xcframework').is_dir():
    subprocess.run(['bash', 'scripts/download-prebuilt-ghosttykit.sh'], cwd=root, env=env, check=True)
command = ['bash', 'scripts/reload.sh', '--tag', 'workspace-icons',
           '--name', 'cmux-custom-build', '--release', '--prod-auth',
           '--derived-data', str(Path.home() / 'Library/Developer/Xcode/DerivedData/cmux-personal'),
           *sys.argv[1:]]
if os.environ.get('GITHUB_ACTIONS') != 'true':
    sys.exit(subprocess.call(command, cwd=root, env=env))

# reload.sh keeps its full compiler log in a file. Publish bounded progress,
# not exported environment values, so a long CI build is observable live.
build_log = Path('/tmp/cmux-reload-workspace-icons.log')
started = time.monotonic()
finished = threading.Event()

def log_tail():
    try:
        with build_log.open('rb') as stream:
            stream.seek(0, 2)
            stream.seek(max(0, stream.tell() - 131072))
            return stream.read().decode('utf-8', errors='replace').splitlines()
    except OSError:
        return []

def progress():
    prefixes = ('Swift', 'Compile', 'PhaseScriptExecution', 'Ld ', 'CodeSign',
                'Copy', 'Process', 'Generate', 'Link', 'Extract', 'Touch',
                'Compiling', 'Finished', 'wireguard-go:', '** BUILD')
    while not finished.wait(30):
        events = [line.strip() for line in log_tail() if line.strip().startswith(prefixes)]
        phase = events[-1][:500] if events else 'waiting for the next compiler event'
        print(f'Build heartbeat [{int(time.monotonic() - started)}s]: {phase}', flush=True)

heartbeat = threading.Thread(target=progress, daemon=True)
heartbeat.start()
try:
    result = subprocess.call(command, cwd=root, env=env)
finally:
    finished.set()
    heartbeat.join(timeout=2)

print(f'Build command finished in {int(time.monotonic() - started)}s (exit {result}).', flush=True)
lines = log_tail()
summaries = [index for index, line in enumerate(lines) if line.strip() == 'Build Timing Summary']
if summaries:
    for line in lines[summaries[-1]:summaries[-1] + 35]:
        if not line.lstrip().startswith('export '):
            print(line[:500], flush=True)
sys.exit(result)
