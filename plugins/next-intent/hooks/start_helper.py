#!/usr/bin/env python3
"""Compile once and keep the macOS Tab-completion helper running."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile


def process_is_alive(pid_path: Path) -> bool:
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def main() -> int:
    if sys.platform != "darwin":
        return 0

    plugin_root = Path(os.environ.get("PLUGIN_ROOT", Path(__file__).resolve().parents[1]))
    plugin_data = Path(os.environ.get("PLUGIN_DATA", tempfile.gettempdir()))
    stable_hooks = plugin_data / "hooks"
    stable_hooks.mkdir(parents=True, exist_ok=True)
    shutil.copy2(plugin_root / "hooks" / "suggest.py", stable_hooks / "suggest.py")
    data_dir = plugin_data / "native-helper"
    data_dir.mkdir(parents=True, exist_ok=True)

    with (data_dir / "start.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = plugin_root / "native" / "NextIntentHelper.m"
        app_bundle = data_dir / "Next Intent Helper.app"
        contents = app_bundle / "Contents"
        macos = contents / "MacOS"
        binary = macos / "NextIntentHelper"
        pid_path = data_dir / "helper.pid"
        binary_is_current = binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime
        if process_is_alive(pid_path) and binary_is_current:
            return 0
        if process_is_alive(pid_path):
            try:
                os.kill(int(pid_path.read_text(encoding="utf-8").strip()), signal.SIGTERM)
            except (OSError, ValueError):
                pass

        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            macos.mkdir(parents=True, exist_ok=True)
            clang = shutil.which("clang") or "/usr/bin/clang"
            temporary = binary.with_name(f".{binary.name}.{os.getpid()}.tmp")
            environment = os.environ.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(data_dir / "clang-module-cache")
            result = subprocess.run(
                [
                    clang,
                    "-fobjc-arc",
                    "-O2",
                    "-framework",
                    "Cocoa",
                    "-framework",
                    "ApplicationServices",
                    str(source),
                    "-o",
                    str(temporary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=50,
                check=False,
                env=environment,
            )
            if result.returncode != 0:
                (data_dir / "compile.log").write_text(result.stdout, encoding="utf-8")
                temporary.unlink(missing_ok=True)
                return 0
            os.replace(temporary, binary)
            info = {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "Next Intent Helper",
                "CFBundleExecutable": "NextIntentHelper",
                "CFBundleIdentifier": "com.yixin.codex.next-intent-helper",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Next Intent Helper",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
            }
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            codesign = shutil.which("codesign") or "/usr/bin/codesign"
            subprocess.run(
                [codesign, "--force", "--sign", "-", str(app_bundle)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

        subprocess.run(
            ["/usr/bin/open", "-g", "-n", str(app_bundle), "--args", str(plugin_data)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
