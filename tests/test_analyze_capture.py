import unittest
from tools.analyze_capture import analyze


def healthy():
    rows = [{"event": "start", "elapsed": 0}]
    rows += [dict(event="sample", elapsed=t, video_frames=30*t,
                  audio_buffers=50*t, video_age=0.01, audio_age=0.01)
             for t in range(1, 1801)]
    rows.append({"event": "stop", "elapsed": 1800, "reason": "user"})
    return rows


class CaptureAnalysisTests(unittest.TestCase):
    def test_sample_delivery_never_claims_vehicle_sync(self):
        result = analyze(healthy())
        self.assertTrue(result["sample_delivery_passed"])
        self.assertFalse(result["vehicle_av_sync_verified"])

    def test_audio_only_fails(self):
        rows = healthy()
        for row in rows[1:-1]:
            row["video_frames"] = 0
            row["video_age"] = None
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_video_stall_at_ten_minutes_is_not_hidden_by_audio(self):
        rows = healthy()
        for row in rows[601:-1]:
            row["video_frames"] = 18000
            row["video_age"] = row["elapsed"] - 600
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_missing_middle_log_cannot_pass(self):
        rows = healthy()
        del rows[600:1100]
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_no_stop_is_incomplete(self):
        self.assertFalse(analyze(healthy()[:-1])["sample_delivery_passed"])

    def test_too_short(self):
        rows = healthy()[:301] + [{"event": "stop", "elapsed": 300, "reason": "user"}]
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_regressing_time_fails(self):
        rows = healthy()
        rows[900]["elapsed"] = 5
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_error_stop_fails(self):
        rows = healthy()
        rows[-1]["reason"] = "stream_error"
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_nan_is_not_treated_as_valid_measurement(self):
        rows = healthy()
        rows[900]["video_age"] = float("nan")
        self.assertFalse(analyze(rows)["sample_delivery_passed"])

    def test_empty_is_unknown(self):
        self.assertFalse(analyze([])["sample_delivery_passed"])


if __name__ == "__main__":
    unittest.main()
