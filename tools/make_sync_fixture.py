"""產生具有共同時間軸的閃光與短音測試素材，不是車機同步測試結果。"""
import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path


def generate(output, duration):
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise RuntimeError("需要 ffmpeg 與 ffprobe")
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # 30 fps / 48 kHz，2、4、6...秒同時閃光及發聲。前兩秒為安靜基線。
    font_candidates = [Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/arial.ttf",
                       Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
                       Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]
    font = next((p for p in font_candidates if p.exists()), None)
    if font is None:
        raise RuntimeError("找不到測試影片字型")
    font_option = "fontfile='" + font.as_posix().replace(":", "\\:") + "':"
    video = (
        "color=c=0x18212b:s=854x480:r=30,"
        "drawbox=x=40:y=40:w=180:h=180:color=white:t=fill:"
        "enable='gte(t,2)*lt(mod(t,2),0.10)',"
        f"drawtext={font_option}text='ES CAST  %{{pts\\:hms}}':fontcolor=white:fontsize=38:x=260:y=100,"
        f"drawtext={font_option}text='FLASH + BEEP / EVERY 2 SECONDS':fontcolor=white:fontsize=24:x=40:y=330,"
        "drawbox=x=40:y=400:w=774:h=8:color=0x4ad9b2:t=fill"
    )
    audio = "aevalsrc=0.18*sin(2*PI*1000*t)*gte(t\\,2)*lt(mod(t\\,2)\\,0.10):s=48000"
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
        "-f", "lavfi", "-i", video, "-f", "lavfi", "-i", audio,
        "-t", str(duration), "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
        "-pix_fmt", "yuv420p", "-g", "60", "-c:a", "aac", "-b:a", "128k",
        "-ar", "48000", "-ac", "2", "-movflags", "+faststart", str(output),
    ], check=True)
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(output)
    ]))
    streams = probe["streams"]
    if {s["codec_type"] for s in streams} != {"video", "audio"}:
        raise RuntimeError("產出沒有雙軌")
    if abs(float(probe["format"]["duration"]) - duration) > 0.1:
        raise RuntimeError("產出長度不符")
    manifest = {"duration_seconds": duration, "fps": 30, "audio_rate": 48000,
                "first_pulse_seconds": 2, "pulse_interval_seconds": 2,
                "pulse_duration_seconds": 0.1, "vehicle_sync_verified": False,
                "probe": probe}
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(output), "duration_seconds": duration,
                      "bytes": output.stat().st_size, "vehicle_sync_verified": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=1800)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 6 <= args.duration <= 3600:
        parser.error("測試長度必須介於 6–3600 秒")
    generate(args.output, args.duration)
