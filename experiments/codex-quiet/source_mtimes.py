"""Reuse source mtimes only when their bytes match a compiler cache snapshot."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess


def safe_file(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        return None
    candidate = root / name
    if candidate.is_symlink() or not candidate.is_file():
        return None
    if not candidate.resolve().is_relative_to(root.resolve()):
        return None
    return candidate


def restore(source, cache):
    try:
        records = json.loads(cache.read_text())
    except (OSError, ValueError):
        return 0
    if not isinstance(records, dict):
        return 0
    restored = 0
    for name, record in records.items():
        if not isinstance(name, str) or not isinstance(record, dict):
            continue
        path = safe_file(source, name)
        if path is None:
            continue
        try:
            timestamp = record.get('mtime_ns')
            if not isinstance(timestamp, int) or timestamp < 0:
                continue
            if hashlib.sha256(path.read_bytes()).hexdigest() != record.get('sha256'):
                continue
            os.utime(path, ns=(path.stat().st_atime_ns, timestamp))
            restored += 1
        except (OSError, OverflowError, ValueError):
            continue
    return restored


def save(source, cache, names=None):
    if names is None:
        output = subprocess.check_output(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'codex-rs'], cwd=source)
        names = [os.fsdecode(name) for name in output.split(b'\0') if name]
    records = {}
    for name in names:
        path = safe_file(source, name)
        if path is None:
            continue
        try:
            records[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mtime_ns': path.stat().st_mtime_ns}
        except OSError:
            continue
    cache.parent.mkdir(parents=True, exist_ok=True)
    temporary = cache.with_suffix('.tmp')
    temporary.write_text(json.dumps(records, sort_keys=True))
    temporary.replace(cache)
    return len(records)
