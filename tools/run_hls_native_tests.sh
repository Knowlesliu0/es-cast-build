#!/usr/bin/env bash
set -euo pipefail
swiftc ios/ESCast/SourceRecoveryObservation.swift tests/source-recovery/main.swift -o /tmp/escast-source-recovery
/tmp/escast-source-recovery
swiftc -parse-as-library ios/ESCast/SourceRecoveryObservation.swift ios/ESCast/SourceRecoveryCoordinator.swift tests/source-recovery-lifecycle/main.swift -o /tmp/escast-source-recovery-lifecycle
/tmp/escast-source-recovery-lifecycle
swiftc -D SOURCE_RECOVERY_OBSERVATION ios/ESCast/CaptureTelemetry.swift tests/source-recovery-telemetry/*.swift -o /tmp/escast-source-recovery-telemetry
/tmp/escast-source-recovery-telemetry
swiftc ios/ESCast/HLS/*.swift tests/hls-core/main.swift -o /tmp/escast-hls-core
/tmp/escast-hls-core
swiftc ios/ESCast/CaptureTermination.swift tests/capture-stop/main.swift -o /tmp/escast-capture-stop
/tmp/escast-capture-stop
command -v ffmpeg || brew install ffmpeg
mkdir -p artifacts
# 60 fps input checks that pacing to 30 fps preserves audio and video time.
ffmpeg -v error -f lavfi \
  -i "color=c=0x18212b:s=854x480:r=60,drawbox=x=40:y=40:w=180:h=180:color=white:t=fill:enable='gte(t,2)*lt(mod(t,2),0.10)'" \
  -f lavfi -i 'aevalsrc=0.18*sin(2*PI*1000*t)*gte(t\,2)*lt(mod(t\,2)\,0.10):s=48000' \
  -t 12 -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -g 120 \
  -c:a aac -b:a 128k -ar 48000 -ac 2 -movflags +faststart artifacts/hls-native-source.mp4
mkdir -p ios/ESCastTests/Fixtures
cp artifacts/hls-native-source.mp4 ios/ESCastTests/Fixtures/hls-native-source.mp4
swiftc -parse-as-library ios/ESCast/HLS/*.swift ios/ESCast/LiveHLSWriter.swift \
  ios/ESCast/LocalHLSServer.swift tests/hls-writer/*.swift -o /tmp/escast-hls-integration
/tmp/escast-hls-integration artifacts/hls-native-source.mp4 artifacts/hls-native-output
ffmpeg -v error -i artifacts/hls-native-output-last-image/stream.m3u8 -map 0:v:0 -map 0:a:0 \
  -vf fps=30 -c:v libx264 -preset ultrafast -crf 18 -c:a copy artifacts/hls-native-last-image.mp4
python3 - <<'PY'
import subprocess
for position in (1, 3, 10):
    pixels = subprocess.check_output(["ffmpeg", "-v", "error", "-ss", str(position),
        "-i", "artifacts/hls-native-last-image.mp4", "-frames:v", "1", "-an",
        "-vf", "crop=100:100:60:60,scale=1:1:flags=area,format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"])
    print(f"Last-source-image pixel at {position}s: {list(pixels)}", flush=True)
    assert len(pixels) == 1, "missing decoded held image"
    assert (pixels[0] < 80 if position == 1 else pixels[0] > 200), "held image is not the latest source update"
PY
python3 tools/verify_fixture.py artifacts/hls-native-last-image.mp4 \
  --pulses 2 --report artifacts/hls-native-last-image-pulses.json
ffmpeg -v error -i artifacts/hls-native-output/stream.m3u8 -map 0:v:0 -map 0:a:0 \
  -c copy artifacts/hls-native-roundtrip.mp4
python3 -c 'import subprocess,json; d=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_format","-show_streams","-of","json","artifacts/hls-native-roundtrip.mp4"])); assert {s["codec_type"] for s in d["streams"]}=={"video","audio"}; assert abs(float(d["format"]["duration"])-12)<0.15; v=next(s for s in d["streams"] if s["codec_type"]=="video"); assert int(v["nb_frames"])==360, v'
python3 tools/verify_fixture.py artifacts/hls-native-roundtrip.mp4 \
  --pulses 2 6 10 --report artifacts/hls-native-pulses.json
ffmpeg -v error -i artifacts/hls-native-output-jittered/stream.m3u8 -map 0:v:0 -map 0:a:0 \
  -c copy artifacts/hls-native-jittered-roundtrip.mp4
python3 -c 'import subprocess,json; d=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_format","-show_streams","-of","json","artifacts/hls-native-jittered-roundtrip.mp4"])); assert {s["codec_type"] for s in d["streams"]}=={"video","audio"}; assert abs(float(d["format"]["duration"])-12)<0.15; v=next(s for s in d["streams"] if s["codec_type"]=="video"); assert int(v["nb_frames"])==360, v'
python3 tools/verify_fixture.py artifacts/hls-native-jittered-roundtrip.mp4 \
  --pulses 2 6 10 --report artifacts/hls-native-jittered-pulses.json
# Decode sparse video onto a 30 Hz observation grid without changing its timeline.
# The omitted 3-6 second interval intentionally removes the 4 second flash.
ffmpeg -v error -i artifacts/hls-native-output-sparse/stream.m3u8 -map 0:v:0 -map 0:a:0 \
  -vf fps=30 -c:v libx264 -preset ultrafast -crf 18 -c:a copy artifacts/hls-native-sparse-roundtrip.mp4
python3 -c 'import subprocess,json; d=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_format","-show_streams","-of","json","artifacts/hls-native-sparse-roundtrip.mp4"])); assert {s["codec_type"] for s in d["streams"]}=={"video","audio"}; assert abs(float(d["format"]["duration"])-12)<0.15'
python3 tools/verify_fixture.py artifacts/hls-native-sparse-roundtrip.mp4 \
  --pulses 2 6 10 --report artifacts/hls-native-sparse-pulses.json
ffmpeg -v error -i artifacts/hls-native-output-sparse-live/stream.m3u8 -map 0:v:0 -map 0:a:0 \
  -vf fps=30 -c:v libx264 -preset ultrafast -crf 18 -c:a copy artifacts/hls-native-sparse-live-roundtrip.mp4
python3 tools/verify_fixture.py artifacts/hls-native-sparse-live-roundtrip.mp4 \
  --pulses 2 6 10 --report artifacts/hls-native-sparse-live-pulses.json
