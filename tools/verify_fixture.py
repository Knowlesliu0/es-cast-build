"""解碼實際 MP4 的閃光/短音並比對；結果僅適用於素材，不代表車機。"""
import argparse
import array
import json
import subprocess
from pathlib import Path


def measure(path, pulse_time):
    start = pulse_time - 0.5
    common = ["ffmpeg", "-v", "error", "-ss", str(start), "-i", str(path), "-t", "1"]
    video = subprocess.check_output(common + [
        "-an", "-vf", "crop=100:100:60:60,scale=1:1:flags=area,format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"])
    audio = array.array("f")
    audio.frombytes(subprocess.check_output(common + [
        "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"]))
    visual = next((i/30 for i, value in enumerate(video) if value > 200), None)
    audible = next((i/48000 for i, value in enumerate(audio) if abs(value) > 0.03), None)
    if visual is None or audible is None:
        return {"pulse_time": pulse_time, "passed": False, "reason": "找不到閃光或短音"}
    offset = (audible - visual) * 1000
    return {"pulse_time": pulse_time, "video_event_seconds": start+visual,
            "audio_event_seconds": start+audible, "audio_minus_video_ms": offset,
            "passed": abs(offset) <= 40}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--pulses", type=float, nargs="+", default=[2, 900, 1798])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    results = [measure(args.video.resolve(), t) for t in args.pulses]
    report = {"fixture_checks_passed": all(r["passed"] for r in results),
              "vehicle_av_sync_verified": False, "results": results,
              "scope": "解碼後的素材脈衝檢查；30 fps 影像時間解析度為 33.3 ms。"}
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        args.report.write_text(text, encoding="utf-8")
    print(text)
    raise SystemExit(0 if report["fixture_checks_passed"] else 1)
