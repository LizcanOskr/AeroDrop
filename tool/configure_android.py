#!/usr/bin/env python3
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)

manifest_path = sys.argv[1]
project_path = Path(sys.argv[2])
tree = ET.parse(manifest_path)
root = tree.getroot()

permissions = {
    "android.permission.INTERNET",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.ACCESS_NETWORK_STATE",
}
present = {
    element.get(f"{{{ANDROID_NS}}}name")
    for element in root.findall("uses-permission")
}
for permission in sorted(permissions - present):
    ET.SubElement(
        root,
        "uses-permission",
        {f"{{{ANDROID_NS}}}name": permission},
    )

application = root.find("application")
if application is None:
    raise SystemExit("Android manifest has no application element")
application.set(f"{{{ANDROID_NS}}}usesCleartextTraffic", "true")
tree.write(manifest_path, encoding="utf-8", xml_declaration=True)

activity_path = (
    project_path
    / "android/app/src/main/kotlin/io/github/lizcanoskr/aerodrop/MainActivity.kt"
)
activity_path.parent.mkdir(parents=True, exist_ok=True)
activity_path.write_text(
    """package io.github.lizcanoskr.aerodrop

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.github.lizcanoskr.aerodrop/multicast"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (multicastLock?.isHeld != true) {
                        val wifi = applicationContext.getSystemService(
                            Context.WIFI_SERVICE
                        ) as WifiManager
                        multicastLock = wifi.createMulticastLock(
                            "aerodrop-discovery"
                        ).apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(null)
                }
                "release" -> {
                    multicastLock?.let {
                        if (it.isHeld) it.release()
                    }
                    multicastLock = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        multicastLock?.let {
            if (it.isHeld) it.release()
        }
        multicastLock = null
        super.onDestroy()
    }
}
""",
    encoding="utf-8",
)
