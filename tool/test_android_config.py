#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = root / "tool/configure_android.py"
android_ns = "{http://schemas.android.com/apk/res/android}"

with tempfile.TemporaryDirectory() as temporary:
    project = Path(temporary)
    manifest = project / "android/app/src/main/AndroidManifest.xml"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
        '<application android:label="AeroDrop" /></manifest>',
        encoding="utf-8",
    )

    for _ in range(2):
        subprocess.run(
            [sys.executable, str(script), str(manifest), str(project)],
            check=True,
        )

    tree = ET.parse(manifest)
    permissions = {
        element.get(android_ns + "name")
        for element in tree.getroot().findall("uses-permission")
    }
    expected = {
        "android.permission.INTERNET",
        "android.permission.ACCESS_WIFI_STATE",
        "android.permission.CHANGE_WIFI_MULTICAST_STATE",
        "android.permission.ACCESS_NETWORK_STATE",
    }
    assert permissions == expected, permissions
    assert tree.getroot().find("application").get(
        android_ns + "usesCleartextTraffic"
    ) == "true"
    activity = project / (
        "android/app/src/main/kotlin/io/github/lizcanoskr/aerodrop/MainActivity.kt"
    )
    assert "createMulticastLock" in activity.read_text(encoding="utf-8")

print("Android manifest and multicast integration checks passed.")
