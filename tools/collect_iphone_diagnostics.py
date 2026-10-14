"""只讀 USB 收集 ES Cast 診斷；不下載影音、不修改手機或自動配對。"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid


SESSION_FILES = frozenset(("capture.jsonl", "hls-status.json", "hls-http.json", "source-recovery.json"))
GROUPS = ("Sessions", "LiveRelayDiagnostics", "PlaybackDiagnostics")
MAX_FILE_BYTES = 16 * 1024 * 1024
UUID_NAME = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")


def uuid_name(value):
    return isinstance(value, str) and UUID_NAME.fullmatch(value) is not None


async def directory(app, path):
    info = await app.stat(path)
    if info.get("st_ifmt") != "S_IFDIR":
        raise ValueError("拒絕非目錄或符號連結")
    return [name for name in await app.listdir(path) if isinstance(name, str)]


def save_verified(output, relative, data):
    """Exclusive creation preserves any existing file; identical files are only read."""
    output = output.resolve()
    destination = output / relative
    if not destination.resolve().is_relative_to(output):
        raise ValueError("本機目標超出指定輸出資料夾")
    candidate = destination
    while candidate != output:
        if candidate.is_symlink():
            raise ValueError("拒絕本機目標路徑中的符號連結")
        candidate = candidate.parent
    destination.parent.mkdir(parents=True, exist_ok=True)
    reused = False
    try:
        with destination.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError:
        if not destination.is_file() or destination.read_bytes() != data:
            raise ValueError("本機已存在不同內容，未覆寫")
        reused = True
    before = destination.stat()
    local = destination.read_bytes()
    after = destination.stat()
    digest = hashlib.sha256(data).hexdigest()
    if (before.st_size != len(data) or after.st_size != len(data)
            or before.st_mtime_ns != after.st_mtime_ns or local != data
            or hashlib.sha256(local).hexdigest() != digest):
        raise ValueError("本機大小、穩定性或 SHA-256 核對失敗")
    return destination, digest, reused


async def collect_file(app, output, remote_path):
    before = await app.stat(remote_path)
    size = before.get("st_size")
    if before.get("st_ifmt") != "S_IFREG":
        raise ValueError("拒絕非一般檔案或符號連結")
    if type(size) is not int or size < 0 or size > MAX_FILE_BYTES or before.get("st_mtime") is None:
        raise ValueError("遠端大小或修改時間無效，或超過16 MiB診斷上限")
    data = await app.get_file_contents(remote_path)
    after = await app.stat(remote_path)
    if (not isinstance(data, bytes) or before["st_size"] != after.get("st_size")
            or len(data) != size or before["st_mtime"] != after.get("st_mtime")
            or after.get("st_ifmt") != "S_IFREG"):
        raise ValueError("遠端讀取前後不穩定或大小不符，未保存")
    relative = Path(remote_path.lstrip("/"))
    destination, digest, reused = save_verified(output, relative, data)
    return {"remote_path": remote_path, "local_path": str(destination), "bytes": len(data),
            "sha256": digest, "remote_mtime": str(after["st_mtime"]), "stable": True,
            "local_size_and_hash_verified": True, "reused_identical_file": reused}


async def collect(app, output):
    """AFC rooted at the selected App container; only allowlisted Documents paths are read."""
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"collection_complete": False, "files": [], "errors": [], "missing_groups": [],
              "read_only": True, "media_downloaded": False,
              "scope": "只複製指定 App 的三類本機診斷；檔案穩定不代表測試已停止或車機成功。"}
    try:
        document_names = await directory(app, "/Documents")
    except Exception as error:
        report["errors"].append({"remote_path": "/Documents", "error": str(error)})
        return report
    paths = []
    for group in GROUPS:
        base = "/Documents/" + group
        if group not in document_names:
            report["missing_groups"].append(group)
            continue
        try:
            names = await directory(app, base)
            if group == "Sessions":
                for session in sorted(set(name for name in names if uuid_name(name))):
                    session_base = base + "/" + session
                    try:
                        filenames = await directory(app, session_base)
                        paths.extend(session_base + "/" + name for name in sorted(SESSION_FILES.intersection(filenames)))
                    except Exception as error:
                        report["errors"].append({"remote_path": session_base, "error": str(error)})
            else:
                suffix = ".jsonl" if group == "LiveRelayDiagnostics" else ".json"
                paths.extend(base + "/" + name for name in sorted(set(names))
                             if name.endswith(suffix) and uuid_name(name[:-len(suffix)]))
        except Exception as error:
            report["errors"].append({"remote_path": base, "error": str(error)})
    for remote_path in paths:
        try:
            report["files"].append(await collect_file(app, output, remote_path))
        except Exception as error:
            report["errors"].append({"remote_path": remote_path, "error": str(error)})
    report["collection_complete"] = bool(report["files"]) and not report["errors"]
    return report


async def collect_usb(udid, bundle, output):
    # Keep these imports optional: offline unit tests and --help need no device SDK.
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.house_arrest import HouseArrestService
    except ImportError as error:
        raise RuntimeError("請使用已安裝 pymobiledevice3 的本機 Python 環境") from error
    async with await create_using_usbmux(serial=udid, connection_type="USB", autopair=False) as device:
        if not device.paired:
            raise RuntimeError("既有手機配對未確認；工具不會建立新配對")
        async with await HouseArrestService.create(device, bundle, documents_only=False) as app:
            return await collect(app, output)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="明確指定 USB 裝置；沒有預設值")
    parser.add_argument("--bundle", required=True, help="自己的 ES Cast 完整簽署 bundle ID；沒有預設值")
    parser.add_argument("--output", required=True, type=Path, help="本機診斷輸出資料夾")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.udid):
        parser.error("--udid 不能空白或包含路徑字元")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle):
        parser.error("--bundle 必須是完整 bundle ID")
    try:
        report = asyncio.run(collect_usb(args.udid, args.bundle, args.output))
        report["requested_bundle"] = args.bundle
        report["explicit_usb_device_selection"] = True
        manifest = Path("collection-verification-" + str(uuid.uuid4()) + ".json")
        payload = json.dumps(report, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
        destination, _, _ = save_verified(args.output, manifest, payload)
        report["verification_manifest"] = str(destination)
    except Exception as error:
        report = {"collection_complete": False, "read_only": True, "media_downloaded": False,
                  "errors": [{"error": str(error)}], "files": []}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["collection_complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
