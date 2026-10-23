#!/usr/bin/env python3
"""Install a built personal cmux without replacing the official app or live sessions."""
from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def require_closed(path: Path) -> None:
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if any(str(path) + "/Contents/" in line for line in processes.splitlines()):
        raise RuntimeError(f"{path.name} is running; finish its sessions and quit it first")


def replace_installation(source: Path, destination: Path, identity: str) -> None:
    """Validate a complete same-volume candidate before an atomic directory swap."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    require_closed(destination)
    with tempfile.TemporaryDirectory(prefix=".cmux-plus-install-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "cmux+.app"
        subprocess.run([sys.executable, str(Path(__file__).resolve()), str(source),
                        "--destination", str(staged), "--runtime-destination", str(destination),
                        "--sign", identity], check=True)
        # The user may have reopened the app while signing. Never replace a live bundle.
        require_closed(destination)
        if destination.exists():
            previous = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
            if previous.get("CFBundleIdentifier") != "com.cmuxterm.app.debug.workspace.icons":
                raise RuntimeError("refusing to replace a different application identity")
            libc = ctypes.CDLL(None, use_errno=True)
            swap = libc.renameatx_np
            swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            swap.restype = ctypes.c_int
            # Darwin: AT_FDCWD = -2; RENAME_SWAP = 2. Both paths share a volume.
            if swap(-2, os.fsencode(staged), -2, os.fsencode(destination), 2) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
            # The retired bundle now occupies the disposable staging path; no backup is kept.
        else:
            os.replace(staged, destination)
    print("Installed cmux+ after validating the replacement. Launch it from Applications or Raycast.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/cmux+.app")
    parser.add_argument("--sign", default="-")
    parser.add_argument("--replace", action="store_true",
                        help="validate a staged copy, then atomically replace a closed installation")
    parser.add_argument("--runtime-destination", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    source = args.source.resolve()
    destination = args.destination.expanduser().absolute()
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    if bundle_id != "com.cmuxterm.app.debug.workspace.icons":
        parser.error("expected the isolated workspace-icons build; refusing another app identity")
    if destination.name != "cmux+.app" or destination == source:
        parser.error("destination must be a separate cmux+.app")
    require_closed(source)
    if args.replace:
        if args.runtime_destination is not None:
            parser.error("--runtime-destination cannot be combined with --replace")
        replace_installation(source, destination, args.sign)
        return
    if destination.exists():
        parser.error("destination already exists; quit the app and use --replace")
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if any(str(source) + "/Contents/MacOS/" in line or str(destination) + "/Contents/MacOS/" in line
           for line in processes.splitlines()):
        parser.error("the source or destination is running; finish its sessions and quit it first")
    destination.parent.mkdir(parents=True, exist_ok=True)
    runtime_destination = args.runtime_destination.expanduser().absolute() if args.runtime_destination else destination
    try:
        subprocess.run(["ditto", str(source), str(destination)], check=True)
        info["CFBundleName"] = "cmux+"
        info["CFBundleDisplayName"] = "cmux+"
        info["CMUXPersonalBuild"] = True
        # The hosted production sign-in rejects development callback schemes.
        # Keep the app's isolated bundle/data identity, but claim the supported
        # cmux:// callback now that the official app has been uninstalled.
        auth_types = [entry for entry in info.get("CFBundleURLTypes", [])
                      if entry.get("CFBundleURLName", "").endswith(".auth")]
        if len(auth_types) != 1:
            raise ValueError("expected exactly one native auth callback registration")
        schemes = auth_types[0].setdefault("CFBundleURLSchemes", [])
        if "cmux" not in schemes:
            schemes.append("cmux")
        info["SUEnableAutomaticChecks"] = False
        info["SUAutomaticallyUpdate"] = False
        info["SUAllowsAutomaticUpdates"] = False
        # Never consume official releases: they omit this fork's changes.
        info["SUFeedURL"] = "https://github.com/arjanflac/cmux/releases/latest/download/personal-appcast.xml"
        env = info.setdefault("LSEnvironment", {})
        for key, value in list(env.items()):
            if isinstance(value, str):
                env[key] = value.replace(str(source), str(runtime_destination))
        # Repackage downloaded CI artifacts too: their original build-machine
        # paths do not match `source` after extraction on another Mac.
        env.update({
            "CMUX_AUTH_ENVIRONMENT": "production",
            "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
            "CMUX_WWW_ORIGIN": "https://cmux.com",
            "CMUX_API_BASE_URL": "https://cmux.com",
            "CMUX_VM_API_BASE_URL": "https://cmux.com",
            "CMUX_IROH_BROKER_BASE_URL": "https://cmux.com",
            "CMUX_BUNDLED_CLI_PATH": str(runtime_destination / "Contents/Resources/bin/cmux"),
            "CMUX_SHELL_INTEGRATION_DIR": str(runtime_destination / "Contents/Resources/shell-integration"),
            "PACKAGE_RESOURCE_BUNDLE_PATH": str(runtime_destination / "Contents/Resources"),
            "CMUXD_UNIX_PATH": str(Path.home() / "Library/Application Support/cmux/cmuxd-dev-workspace-icons.sock"),
            "CMUXTERM_REPO_ROOT": str(Path(__file__).resolve().parent.parent),
        })
        (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        # SwiftPM's Release accessor has no environment override. Standalone CLI
        # processes search beside their executable, rather than the host app's resources.
        resources = destination / "Contents/Resources"
        for bundle in resources.glob("*.bundle"):
            link = resources / "bin" / bundle.name
            if not link.exists():
                link.symlink_to(Path("..") / bundle.name)
        subprocess.run(["codesign", "--force", "--sign", args.sign, "--timestamp=none",
                        "--preserve-metadata=entitlements,flags", "--generate-entitlement-der",
                        str(destination)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
        subprocess.run([str(resources / "bin/cmux"), "--help"], check=True,
                       stdout=subprocess.DEVNULL)
    except BaseException:
        shutil.rmtree(destination)
        raise
    # Keep the tested identity: icons, workspace layout, and permissions stay in their existing domain.
    for key, value in (("showSidebarDevBuildBanner", "false"),
                       ("SUEnableAutomaticChecks", "false"), ("SUAutomaticallyUpdate", "false")):
        subprocess.run(["defaults", "write", bundle_id, key, "-bool", value], check=True)
    print("Installed cmux+. Launch it from Applications or Raycast.")


if __name__ == "__main__":
    main()
