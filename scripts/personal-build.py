#!/usr/bin/env python3
"""Build cmux+ through the repository wrapper, with bounded compiler concurrency."""
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
tools = Path.home() / 'Library/Caches/cmux-personal-tools'
tools.mkdir(parents=True, exist_ok=True)
swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
zig = shutil.which('zig')
if not zig:
    sys.exit('zig must be installed at the version required by ghostty/build.zig.zon')
compiler = '#!/bin/sh\ncase " $* " in\n *" -frontend "*|*" -package-description-version "*) exec ' + shlex.quote(swift) + ' "$@" ;;\n *) exec ' + shlex.quote(swift) + ' "$@" -enable-batch-mode -driver-batch-count 256 -j1 ;;\nesac\n'
selector = 'SWIFT_EXEC=$(CMUX_PERSONAL_SWIFT_EXEC_$(TARGET_NAME):default=' + swift + ')'
xcode = '#!/bin/sh\ncase " $* " in\n *" -project cmux.xcodeproj "*) exec /usr/bin/xcodebuild -jobs 1 "$@" ONLY_ACTIVE_ARCH=YES ARCHS=arm64 SWIFT_COMPILATION_MODE=incremental SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=1 ' + shlex.quote(selector) + ' ' + shlex.quote('CMUX_PERSONAL_SWIFT_EXEC_cmux=' + str(tools / 'swiftc')) + ' ;;\n *) exec /usr/bin/xcodebuild "$@" ;;\nesac\n'
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
sys.exit(subprocess.call(['bash', 'scripts/reload.sh', '--tag', 'workspace-icons',
                         '--name', 'cmux+', '--release', '--prod-auth',
                         '--derived-data', str(Path.home() / 'Library/Developer/Xcode/DerivedData/cmux-personal'),
                         *sys.argv[1:]], cwd=root, env=env))
