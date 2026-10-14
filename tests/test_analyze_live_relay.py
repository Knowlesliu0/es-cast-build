import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools import analyze_live_relay as relay


RUN = "11111111-1111-4111-8111-111111111111"
CAPTURE = "22222222-2222-4222-8222-222222222222"
OTHER = "33333333-3333-4333-8333-333333333333"


def row(event, elapsed, **changes):
    result = {
        "event": event, "relay_session_uuid": RUN,
        "capture_session_uuid": CAPTURE, "bound_capture_session_uuid": CAPTURE,
        "app_build": "12", "uptime_seconds": 1000 + elapsed,
        "elapsed_seconds": elapsed, "source_active": True, "source_ready": True,
        "consumer_requested": True, "item_status": 1, "time_control_status": 2,
        "player_rate": 1.0, "player_time_seconds": max(0, elapsed - 1),
        "external_playback_active": False, "consumer_muted": True,
        "decoded_pixel_observations": max(0, int(elapsed - 1)),
        "decoded_brightness_changes": max(0, int(elapsed // 3)),
    }
    result.update(changes)
    return result


def healthy(external=False):
    rows = [row("prepared", 0, capture_session_uuid=None,
                bound_capture_session_uuid=None, source_active=False,
                source_ready=False, consumer_requested=False, item_status=-1,
                time_control_status=0, player_rate=0, player_time_seconds=None)]
    rows.append(row("consumer_started", 1, item_status=0,
                    time_control_status=0, player_rate=0))
    rows += [row("sample", t, external_playback_active=external,
                 consumer_muted=not external) for t in range(2, 63)]
    rows.append(row("stop", 63, consumer_requested=False,
                    time_control_status=0, player_rate=0, reason="user"))
    return rows


class LiveRelayAnalysisTests(unittest.TestCase):
    def test_muted_phone_progress_never_claims_vehicle_or_source_visibility(self):
        result = relay.analyze(healthy())
        self.assertEqual(result["analysis_status"], "complete")
        self.assertEqual(result["phone_pipeline_status"], "observed")
        self.assertTrue(result["player_clock_advanced"])
        self.assertTrue(result["local_decoded_pixels_observed"])
        self.assertFalse(result["external_playback_flag_observed"])
        for key in ("source_visible_content_verified", "vehicle_playback_verified",
                    "vehicle_av_sync_verified", "audible_output_verified",
                    "feedback_exclusion_verified"):
            self.assertFalse(result[key], key)

    def test_external_flag_with_audio_request_still_does_not_verify_vehicle(self):
        result = relay.analyze(healthy(external=True))
        self.assertTrue(result["external_playback_flag_observed"])
        self.assertTrue(result["consumer_audio_requested_observed"])
        self.assertFalse(result["vehicle_playback_verified"])
        self.assertFalse(result["audible_output_verified"])

    def test_empty_and_missing_terminal_stop_are_unknown(self):
        for rows in ([], healthy()[:-1]):
            with self.subTest(rows=len(rows)):
                result = relay.analyze(rows)
                self.assertEqual(result["analysis_status"], "unknown")
                self.assertEqual(result["phone_pipeline_status"], "unknown")

    def test_rows_after_stop_and_second_consumer_are_unknown(self):
        for rows in (healthy() + [row("sample", 64)],
                     healthy()[:3] + [row("consumer_started", 3)] + healthy()[4:]):
            with self.subTest(rows=rows):
                self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_mixed_run_build_and_invalid_binding_are_unknown(self):
        for change in ({"relay_session_uuid": OTHER}, {"app_build": "13"},
                       {"bound_capture_session_uuid": OTHER},
                       {"capture_session_uuid": None}):
            rows = healthy()
            rows[5].update(change)
            with self.subTest(change=change):
                self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_consumer_cannot_start_without_current_source_ready(self):
        rows = healthy()
        rows[1]["source_ready"] = False
        self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_changing_both_capture_ids_cannot_hide_switch_to_another_source(self):
        rows = healthy()
        for record in rows[20:]:
            record.update(capture_session_uuid=OTHER, bound_capture_session_uuid=OTHER)
        self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_midrun_player_clock_reset_cannot_be_hidden_by_end_progress(self):
        rows = healthy()
        rows[20]["player_time_seconds"] = 0
        self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_other_events_do_not_fill_missing_periodic_playback_observations(self):
        rows = healthy()
        for record in rows[20:30]:
            record["event"] = "time_control_changed"
        self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_short_external_event_is_reported_as_flag_only(self):
        rows = healthy()
        rows.insert(5, row("external_playback_changed", 4.5,
                           external_playback_active=True, consumer_muted=False,
                           decoded_pixel_observations=3, decoded_brightness_changes=1))
        result = relay.analyze(rows)
        self.assertTrue(result["external_playback_flag_observed"])
        self.assertFalse(result["vehicle_playback_verified"])

    def test_missing_or_invalid_measurement_cannot_pass(self):
        mutations = [lambda r: r.pop("consumer_muted"),
                     lambda r: r.update(player_time_seconds=float("nan")),
                     lambda r: r.update(decoded_pixel_observations=True),
                     lambda r: r.update(external_playback_active="false")]
        for mutate in mutations:
            rows = healthy()
            mutate(rows[5])
            with self.subTest(mutate=mutate):
                self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_time_counter_regressions_and_missing_middle_are_unknown(self):
        for key, value in (("elapsed_seconds", 0), ("uptime_seconds", 0),
                           ("decoded_pixel_observations", 0)):
            rows = healthy()
            rows[10][key] = value
            with self.subTest(key=key):
                self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")
        rows = healthy()
        del rows[20:30]
        self.assertEqual(relay.analyze(rows)["analysis_status"], "unknown")

    def test_raw_counts_without_clock_progress_do_not_observe_pipeline(self):
        rows = healthy()
        for record in rows[2:]:
            record["player_time_seconds"] = 0
            record["player_rate"] = 0
            record["time_control_status"] = 0
        result = relay.analyze(rows)
        self.assertEqual(result["analysis_status"], "complete")
        self.assertEqual(result["phone_pipeline_status"], "not_observed")
        self.assertFalse(result["player_clock_advanced"])

    def test_failed_stop_and_unmuted_phone_are_failures(self):
        rows = healthy()
        rows[-1]["reason"] = "item_failed"
        self.assertEqual(relay.analyze(rows)["phone_pipeline_status"], "failed")
        rows = healthy()
        rows[5]["consumer_muted"] = False
        self.assertEqual(relay.analyze(rows)["phone_pipeline_status"], "failed")

    def test_short_progress_is_insufficient(self):
        rows = healthy()[:12] + [row("stop", 12, consumer_requested=False,
                                    player_rate=0, time_control_status=0, reason="user")]
        self.assertEqual(relay.analyze(rows)["phone_pipeline_status"], "not_observed")

    def test_capture_join_requires_matching_uuid_and_keeps_visibility_unknown(self):
        capture = [{"event": "start", "elapsed": 0, "uptime_seconds": 1001,
                    "capture_session_uuid": CAPTURE, "app_build": "12"}]
        capture += [dict(event="sample", elapsed=t, video_frames=30*t,
                         audio_buffers=50*t, video_age=0.01, audio_age=0.01)
                    for t in range(1, 64)]
        capture.append({"event": "stop", "elapsed": 63, "reason": "user"})
        matched = relay.analyze(healthy(), capture_rows=capture,
                                capture_session_uuid=CAPTURE)
        self.assertTrue(matched["capture_sample_delivery_passed"])
        self.assertFalse(matched["source_visible_content_verified"])
        mismatch = relay.analyze(healthy(), capture_rows=capture,
                                 capture_session_uuid=OTHER)
        self.assertEqual(mismatch["analysis_status"], "unknown")

    def test_old_capture_without_identity_is_unknown_when_join_requested(self):
        capture = [{"event": "start", "elapsed": 0},
                   {"event": "stop", "elapsed": 63, "reason": "user"}]
        result = relay.analyze(healthy(), capture_rows=capture,
                               capture_session_uuid=CAPTURE)
        self.assertEqual(result["analysis_status"], "unknown")
        self.assertIsNone(result["capture_sample_delivery_passed"])

    def test_cli_malformed_json_and_non_objects_return_unknown(self):
        for content in ('{broken}\n', '[]\n', '{"event":"sample","event":"stop"}\n'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "relay.jsonl"
                path.write_text(content, encoding="utf-8")
                process = subprocess.run([sys.executable, "tools/analyze_live_relay.py", str(path)],
                                         capture_output=True, text=True, encoding="utf-8")
                self.assertEqual(process.returncode, 2)
                self.assertEqual(json.loads(process.stdout)["analysis_status"], "unknown")

    def test_cli_complete_muted_probe_returns_phone_only_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "relay.jsonl"
            path.write_text("".join(json.dumps(r) + "\n" for r in healthy()), encoding="utf-8")
            process = subprocess.run([sys.executable, "tools/analyze_live_relay.py", str(path)],
                                     capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(process.returncode, 0, process.stderr)
            result = json.loads(process.stdout)
            self.assertEqual(result["phone_pipeline_status"], "observed")
            self.assertFalse(result["vehicle_playback_verified"])


if __name__ == "__main__":
    unittest.main()
