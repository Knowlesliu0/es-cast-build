"""判讀手機即時接收診斷；不驗證實際車機畫面、可聽聲音或影音同步。"""
import argparse
import json
import math
from pathlib import Path
import sys
import uuid

try:
    from .analyze_capture import analyze as analyze_capture
except ImportError:
    from analyze_capture import analyze as analyze_capture


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def uuid_text(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = str(uuid.UUID(value))
    except ValueError:
        return None
    return parsed if value.lower() == parsed else None


def unknown(reasons):
    return {
        "analysis_status": "unknown", "phone_pipeline_status": "unknown",
        "log_complete": False, "reasons": sorted(set(reasons)),
        "player_clock_advanced": False, "local_decoded_pixels_observed": False,
        "external_playback_flag_observed": False, "consumer_audio_requested_observed": False,
        "capture_sample_delivery_passed": None,
        "source_visible_content_verified": False, "vehicle_playback_verified": False,
        "vehicle_av_sync_verified": False, "audible_output_verified": False,
        "feedback_exclusion_verified": False,
        "scope": "只判讀手機管線與系統外播旗標；不判定物理車機畫面、可聽聲音、音訊回授或影音同步。",
    }


def analyze(rows, min_seconds=60, capture_rows=None, capture_session_uuid=None):
    """完整紀錄與實際量測分開；資料損毀時不保留任何成功推論。"""
    invalid = []
    if not number(min_seconds) or min_seconds <= 0:
        return unknown(["最低觀察時間必須為正數"])
    if not rows or any(not isinstance(record, dict) for record in rows):
        return unknown(["空紀錄或每行不是 JSON 物件"])
    if rows[0].get("event") not in ("prepared", "prepare_error"):
        invalid.append("缺少準備開始紀錄")
    if rows[-1].get("event") != "stop" or not isinstance(rows[-1].get("reason"), str) or not rows[-1]["reason"]:
        invalid.append("缺少最後停止原因")
    if sum(record.get("event") == "stop" for record in rows) != 1:
        invalid.append("停止紀錄不唯一或缺少")
    if sum(record.get("event") == "consumer_started" for record in rows) > 1:
        invalid.append("同次診斷重複啟動接收器")
    run_id = uuid_text(rows[0].get("relay_session_uuid"))
    build = rows[0].get("app_build")
    if not run_id or not isinstance(build, str) or not build:
        invalid.append("缺少有效 session 或 build")
    last_elapsed = last_uptime = -1
    counts = (0, 0)
    started = []
    samples = []
    failures = []
    last_player_time = None
    bool_keys = ("source_active", "source_ready", "consumer_requested",
                 "external_playback_active", "consumer_muted")
    counter_keys = ("decoded_pixel_observations", "decoded_brightness_changes")
    for index, record in enumerate(rows):
        if not isinstance(record.get("event"), str) or not record["event"]:
            invalid.append("事件欄位無效")
        if uuid_text(record.get("relay_session_uuid")) != run_id or record.get("app_build") != build:
            invalid.append("混用不同 relay session 或 build")
        elapsed, uptime = record.get("elapsed_seconds"), record.get("uptime_seconds")
        if not number(elapsed) or elapsed < 0 or not number(uptime) or uptime < 0:
            invalid.append("時間欄位無效")
        else:
            if elapsed < last_elapsed or uptime < last_uptime:
                invalid.append("診斷時間倒退")
            if last_elapsed >= 0 and (elapsed - last_elapsed > 3 or uptime - last_uptime > 3):
                invalid.append("紀錄間隔超過三秒，不能確認完整觀察")
            last_elapsed, last_uptime = elapsed, uptime
        if any(type(record.get(key)) is not bool for key in bool_keys):
            invalid.append("必要布林欄位缺少或無效")
        if record.get("item_status") not in (-1, 0, 1, 2) or type(record.get("item_status")) is not int:
            invalid.append("播放器 item 狀態無效")
        if record.get("time_control_status") not in (0, 1, 2) or type(record.get("time_control_status")) is not int:
            invalid.append("播放器 time control 狀態無效")
        for key in ("player_rate", "player_time_seconds"):
            value = record.get(key)
            if key == "player_time_seconds" and value is None and record.get("item_status") != 1:
                continue
            if not number(value) or value < 0:
                invalid.append("播放器時間或速率無效")
        current_counts = tuple(record.get(key) for key in counter_keys)
        if any(not number(value) or value < 0 or value != int(value) for value in current_counts):
            invalid.append("解碼觀察計數無效")
        elif any(value < prior for value, prior in zip(current_counts, counts)):
            invalid.append("解碼觀察計數倒退")
        else:
            counts = current_counts
        for key in ("capture_session_uuid", "bound_capture_session_uuid"):
            if key not in record or record[key] is not None and not uuid_text(record[key]):
                invalid.append("擷取 session 欄位缺少或無效")
        if record.get("consumer_requested") is True:
            current = uuid_text(record.get("capture_session_uuid"))
            bound = uuid_text(record.get("bound_capture_session_uuid"))
            if not current or current != bound or record.get("source_active") is not True or record.get("source_ready") is not True:
                invalid.append("接收器未綁定同次已就緒擷取")
            if started and bound != uuid_text(started[0][1].get("bound_capture_session_uuid")):
                invalid.append("接收期間改用另一個擷取 session")
            if record.get("item_status") == 1 and number(record.get("player_time_seconds")):
                player_time = record["player_time_seconds"]
                if last_player_time is not None and player_time < last_player_time:
                    invalid.append("同次接收播放器時鐘倒退")
                last_player_time = player_time
        if record.get("event") == "consumer_started":
            if record.get("consumer_requested") is not True:
                invalid.append("接收啟動事件與請求狀態不符")
            started.append((index, record))
        if record.get("event") == "sample" and record.get("consumer_requested") is True:
            samples.append((index, record))
        if record.get("consumer_muted") is False and record.get("external_playback_active") is not True:
            failures.append("未有外部影片旗標卻解除手機接收靜音")
        if record.get("event") in ("prepare_error", "item_failed") or record.get("item_status") == 2:
            failures.append("手機準備或播放器回報失敗")
    if samples and (not started or samples[0][0] <= started[0][0]):
        invalid.append("播放樣本早於接收啟動或缺少啟動紀錄")
    if any(current[1]["elapsed_seconds"] - prior[1]["elapsed_seconds"] > 3
           for prior, current in zip(samples, samples[1:])
           if number(current[1].get("elapsed_seconds")) and number(prior[1].get("elapsed_seconds"))):
        invalid.append("接收定期樣本間隔超過三秒")
    if invalid:
        return unknown(invalid)

    result = unknown([])
    result.update(analysis_status="complete", log_complete=True,
                  relay_session_uuid=run_id, app_build=build, sample_rows=len(samples),
                  duration_seconds=last_elapsed, stop_reason=rows[-1]["reason"],
                  consumer_started=bool(started), decoded_pixel_observations=counts[0],
                  decoded_brightness_changes=counts[1])
    bound_id = uuid_text(started[0][1].get("bound_capture_session_uuid")) if started else None
    result["bound_capture_session_uuid"] = bound_id
    active_rows = [record for record in rows if record["consumer_requested"]]
    playing = [record for _, record in samples if record["item_status"] == 1
               and record["time_control_status"] == 2 and record["player_rate"] > 0]
    clock_progress = max(0, playing[-1]["player_time_seconds"] - playing[0]["player_time_seconds"]) if len(playing) > 1 else 0
    result["player_clock_progress_seconds"] = clock_progress
    result["player_clock_advanced"] = clock_progress > 0
    result["local_decoded_pixels_observed"] = bool(active_rows and active_rows[-1]["decoded_pixel_observations"] > 0)
    result["local_brightness_change_observed"] = bool(active_rows and active_rows[-1]["decoded_brightness_changes"] > 0)
    result["external_playback_flag_observed"] = any(record["external_playback_active"] for record in active_rows)
    result["consumer_audio_requested_observed"] = any(record["external_playback_active"] and not record["consumer_muted"] for record in active_rows)
    if rows[-1]["reason"] not in ("user", "capture_stopped", "rearmed"):
        failures.append("非正常或提前停止：" + rows[-1]["reason"])
    if capture_rows is not None:
        capture_start = capture_rows[0] if capture_rows and isinstance(capture_rows[0], dict) else {}
        capture_id = uuid_text(capture_start.get("capture_session_uuid"))
        requested_id = uuid_text(capture_session_uuid) if capture_session_uuid is not None else capture_id
        if not bound_id or capture_id != bound_id or requested_id != bound_id:
            return unknown(["擷取紀錄缺少同次 UUID，或與接收器綁定不符"])
        if capture_start.get("app_build") != build or not number(capture_start.get("uptime_seconds")):
            return unknown(["擷取紀錄缺少同次 build 或單調時間"])
        if any(not isinstance(record, dict) for record in capture_rows):
            return unknown(["擷取紀錄不是 JSON 物件"])
        capture_result = analyze_capture(capture_rows, min_seconds)
        result["capture_sample_delivery_passed"] = capture_result["sample_delivery_passed"]
        result["capture_sample_delivery_reasons"] = capture_result["reasons"]
        result["capture_join_status"] = "matched"
    else:
        result["capture_join_status"] = "not_requested"
    if failures:
        result.update(phone_pipeline_status="failed", reasons=sorted(set(failures)))
    elif not playing or clock_progress < min_seconds:
        result.update(phone_pipeline_status="not_observed", reasons=["未觀察到足夠時間的已就緒手機播放器時鐘進展"])
    else:
        result.update(phone_pipeline_status="observed", reasons=[])
    result["limitations"] = ["手機時鐘、像素抽樣與亮度變化不證明來源持續提供新內容。",
                             "外播旗標與音訊請求不證明車機有圖、有聲或排除回授。",
                             "本結果不取代三次各30分鐘及實際車機影音差量測。"]
    return result


def read_rows(path):
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("JSON 有重複欄位")
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError("JSON 有非有限數字：" + value)

    rows = [json.loads(line, object_pairs_hook=object_pairs, parse_constant=invalid_constant)
            for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    if any(not isinstance(record, dict) for record in rows):
        raise ValueError("每行必須是 JSON 物件")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--min-seconds", type=float, default=60)
    parser.add_argument("--capture-log", type=Path, help="選配：同次 Sessions/<UUID>/capture.jsonl")
    parser.add_argument("--capture-session-uuid", help="選配：再次核對擷取 UUID，不能補造舊紀錄缺少的身分")
    args = parser.parse_args()
    if not number(args.min_seconds) or args.min_seconds <= 0:
        parser.error("--min-seconds 必須為正數")
    if args.capture_session_uuid and (not args.capture_log or not uuid_text(args.capture_session_uuid)):
        parser.error("--capture-session-uuid 必須是有效 UUID，且同時提供 --capture-log")
    try:
        result = analyze(read_rows(args.log), args.min_seconds,
                         read_rows(args.capture_log) if args.capture_log else None,
                         args.capture_session_uuid)
    except (OSError, ValueError) as error:
        result = unknown([f"不能判讀：{error}"])
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 2 if result["analysis_status"] == "unknown" else 0 if result["phone_pipeline_status"] == "observed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
