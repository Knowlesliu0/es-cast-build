"""檢查擷取樣本供應；不判定畫面內容或車機影音同步。"""
import argparse
import json
import math
from pathlib import Path


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def analyze(rows, min_seconds=1800):
    reasons = set()
    samples = []
    previous_time = -1
    previous_counts = (0, 0)
    if not rows or rows[0].get("event") != "start":
        reasons.add("缺少開始紀錄")
    if not rows or rows[-1].get("event") != "stop" or rows[-1].get("reason") != "user":
        reasons.add("缺少正常結束紀錄")
    for row in rows:
        elapsed = row.get("elapsed")
        if not number(elapsed) or elapsed < 0:
            reasons.add("時間欄位無效")
            continue
        if elapsed < previous_time:
            reasons.add("紀錄時間倒退")
        if previous_time >= 0 and elapsed - previous_time > 3:
            reasons.add("紀錄間隔超過三秒")
        previous_time = elapsed
        if row.get("event") == "error":
            reasons.add("擷取回報錯誤")
        if row.get("event") != "sample":
            continue
        samples.append(row)
        counts = (row.get("video_frames"), row.get("audio_buffers"))
        for count, old_count in zip(counts, previous_counts):
            if not number(count) or count < 0 or count != int(count):
                reasons.add("樣本數無效")
            elif count < old_count:
                reasons.add("樣本計數倒退")
        previous_counts = tuple(c if number(c) else 0 for c in counts)
        if elapsed > 5:
            for key, label in (("video_age", "影像"), ("audio_age", "音訊")):
                age = row.get(key)
                if not number(age) or age < 0 or age > 2:
                    reasons.add(f"{label}樣本缺少或超過兩秒未更新")
    duration = previous_time if previous_time >= 0 else 0
    if duration < min_seconds:
        reasons.add("測試時間不足")
    if not samples:
        reasons.add("沒有樣本統計")
    elif any(not number(samples[-1].get(k)) or samples[-1][k] <= 0
             for k in ("video_frames", "audio_buffers")):
        reasons.add("沒有取得雙軌樣本")
    return {
        "sample_delivery_passed": not reasons,
        "vehicle_av_sync_verified": False,
        "visible_content_verified": False,
        "duration_seconds": duration,
        "sample_rows": len(samples),
        "reasons": sorted(reasons),
        "scope": "只檢查樣本供應。PTS、樣本計數不能證明車機影像可見或影音同步。",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--min-seconds", type=float, default=1800)
    args = parser.parse_args()
    if not math.isfinite(args.min_seconds) or args.min_seconds <= 0:
        parser.error("--min-seconds 必須為正數")
    try:
        rows = [json.loads(line) for line in args.log.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
        if any(not isinstance(row, dict) for row in rows):
            raise ValueError("每行必須是 JSON 物件")
        result = analyze(rows, args.min_seconds)
    except (OSError, ValueError) as error:
        result = {"sample_delivery_passed": False, "vehicle_av_sync_verified": False,
                  "reasons": [f"不能判讀：{error}"]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["sample_delivery_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
