#!/usr/bin/env python3
"""Install a built personal cmux without replacing the official app or live sessions."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/cmux Personal.app")
    parser.add_argument("--sign", default="-")
    args = parser.parse_args()
    source = args.source.resolve()
    destination = args.destination.expanduser().absolute()
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    if bundle_id != "com.cmuxterm.app.debug.workspace.icons":
        parser.error("expected the isolated workspace-icons build; refusing another app identity")
    if destination.name != "cmux Personal.app" or destination == source:
        parser.error("destination must be a separate cmux Personal.app")
    if destination.exists():
        parser.error("destination already exists; quit it and explicitly remove that installation before replacing it")
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if any(str(source) + "/Contents/MacOS/" in line or str(destination) + "/Contents/MacOS/" in line
           for line in processes.splitlines()):
        parser.error("the source or destination is running; finish its sessions and quit it first")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(["ditto", str(source), str(destination)], check=True)
        info["CFBundleName"] = "cmux Personal"
        info["CFBundleDisplayName"] = "cmux Personal"
        info["CMUXPersonalBuild"] = True
        info["SUEnableAutomaticChecks"] = False
        info["SUAutomaticallyUpdate"] = False
        info["SUAllowsAutomaticUpdates"] = False
        # Never consume official releases: they omit this fork's changes.
        info["SUFeedURL"] = "https://github.com/arjanflac/cmux/releases/latest/download/personal-appcast.xml"
        env = info.setdefault("LSEnvironment", {})
        for key, value in list(env.items()):
            if isinstance(value, str):
                env[key] = value.replace(str(source), str(destination))
        env["PACKAGE_RESOURCE_BUNDLE_PATH"] = str(destination / "Contents/Resources")
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
    print("Installed cmux Personal. Launch it from Applications or Raycast.")


if __name__ == "__main__":
    main()
