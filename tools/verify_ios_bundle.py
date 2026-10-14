"""Validate the packaged iOS configuration, independently of build success."""
import argparse
import json
import plistlib
from pathlib import Path
import zipfile


def verify(path, source_recovery=False):
    path = Path(path)
    if path.is_dir():
        info = plistlib.loads((path / "Info.plist").read_bytes())
        executable_exists = (path / info.get("CFBundleExecutable", "")).is_file()
    else:
        with zipfile.ZipFile(path) as archive:
            candidates = [name for name in archive.namelist()
                          if name.startswith("Payload/") and name.count("/") == 2
                          and name.endswith(".app/Info.plist")]
            if len(candidates) != 1:
                raise ValueError("Expected exactly one application Info.plist")
            info_path = candidates[0]
            info = plistlib.loads(archive.read(info_path))
            executable_path = info_path.rsplit("/", 1)[0] + "/" + info.get("CFBundleExecutable", "")
            executable_exists = executable_path in archive.namelist()
    failures = []
    expected = {
        "CFBundleIdentifier": "tw.escast.probe",
        "CFBundleDisplayName": "ES Cast 驗證版",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "13",
        "MinimumOSVersion": "27.0",
        "UIDeviceFamily": [1],
        "ESCastSourceRecoveryObservation": "YES" if source_recovery else "NO",
        "AVInitialRouteSharingPolicy": "LongFormVideo",
    }
    if source_recovery:
        expected.update(CFBundleIdentifier="tw.escast.source-recovery",
                        CFBundleDisplayName="ES Cast 來源觀察")
    for key, value in expected.items():
        if info.get(key) != value:
            failures.append(f"{key}: expected {value!r}, got {info.get(key)!r}")
    if not {"screen-capture", "audio"}.issubset(info.get("UIBackgroundModes", [])):
        failures.append("Missing required capture/playback background modes")
    for key in ("NSScreenCaptureUsageDescription", "NSLocalNetworkUsageDescription"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            failures.append(f"Missing {key}")
    for key in ("UILaunchScreen", "UIApplicationSceneManifest"):
        if not isinstance(info.get(key), dict):
            failures.append(f"Missing {key}")
    if not info.get("UISupportedInterfaceOrientations"):
        failures.append("Missing supported orientations")
    if not executable_exists:
        failures.append("Missing app executable")
    fixture = "CarTestAssets/ESCast-Car-Test-60s.mp4"
    if path.is_dir():
        fixture_exists = (path / fixture).is_file() and (path / fixture).stat().st_size > 1024
    else:
        with zipfile.ZipFile(path) as archive:
            fixture_path = info_path.rsplit("/", 1)[0] + "/" + fixture
            fixture_exists = (fixture_path in archive.namelist()
                              and archive.getinfo(fixture_path).file_size > 1024)
    if not fixture_exists:
        failures.append("Missing offline car test movie")
    return {"bundle_configuration_passed": not failures, "failures": failures,
            "bundle_id": info.get("CFBundleIdentifier"), "sdk": info.get("DTSDKName"),
            "device_playback_verified": False, "vehicle_av_sync_verified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Built .app directory or unsigned .ipa")
    parser.add_argument("--source-recovery", action="store_true")
    args = parser.parse_args()
    try:
        result = verify(args.path, args.source_recovery)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        result = {"bundle_configuration_passed": False, "failures": [str(error)]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result["bundle_configuration_passed"] else 1)
