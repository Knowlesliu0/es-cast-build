import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools import collect_iphone_diagnostics as collector


SESSION = "22222222-2222-4222-8222-222222222222"
RUN = "11111111-1111-4111-8111-111111111111"


class FakeAFC:
    """Only the three read operations used by the production adapter are available."""
    def __init__(self):
        self.contents = {
            f"/Documents/Sessions/{SESSION}/capture.jsonl": b'{"event":"stop"}\n',
            f"/Documents/Sessions/{SESSION}/hls-status.json": b'{"ready":false}',
            f"/Documents/Sessions/{SESSION}/capture.mp4": b"PRIVATE MEDIA",
            f"/Documents/LiveRelayDiagnostics/{RUN}.jsonl": b'{"event":"stop"}\n',
            f"/Documents/PlaybackDiagnostics/{RUN}.json": b'{"snapshot_only":true}',
            "/Documents/LiveRelayDiagnostics/not-a-uuid.jsonl": b"IGNORE",
        }
        self.directories = {"/Documents": ["Sessions", "LiveRelayDiagnostics", "PlaybackDiagnostics", "Other"],
                            "/Documents/Sessions": [SESSION, "../escape", "invalid"],
                            f"/Documents/Sessions/{SESSION}": ["capture.jsonl", "hls-status.json", "capture.mp4", "HLS"],
                            "/Documents/LiveRelayDiagnostics": [f"{RUN}.jsonl", "not-a-uuid.jsonl", "../escape.jsonl"],
                            "/Documents/PlaybackDiagnostics": [f"{RUN}.json"]}
        self.reads = []
        self.metadata_sequences = {}

    async def listdir(self, path):
        return list(self.directories[path])

    async def stat(self, path):
        if path in self.metadata_sequences:
            sequence = self.metadata_sequences[path]
            return dict(sequence.pop(0) if len(sequence) > 1 else sequence[0])
        if path in self.directories:
            return {"st_ifmt": "S_IFDIR", "st_size": 0, "st_mtime": 1}
        return {"st_ifmt": "S_IFREG", "st_size": len(self.contents[path]), "st_mtime": 1}

    async def get_file_contents(self, path):
        self.reads.append(path)
        return self.contents[path]


class DiagnosticCollectorTests(unittest.IsolatedAsyncioTestCase):
    async def test_downloads_only_uuid_diagnostics_and_verifies_real_local_bytes(self):
        remote = FakeAFC()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            report = await collector.collect(remote, output)
            self.assertTrue(report["collection_complete"])
            self.assertEqual(len(report["files"]), 4)
            self.assertEqual(len(remote.reads), 4)
            self.assertFalse(any(".mp4" in path or "HLS/" in path for path in remote.reads))
            self.assertFalse(any("escape" in path or "not-a-uuid" in path for path in remote.reads))
            destination = output / "Documents" / "LiveRelayDiagnostics" / f"{RUN}.jsonl"
            self.assertEqual(destination.read_bytes(), b'{"event":"stop"}\n')
            entry = next(record for record in report["files"] if record["remote_path"].endswith(f"{RUN}.jsonl"))
            self.assertEqual(entry["sha256"], hashlib.sha256(b'{"event":"stop"}\n').hexdigest())

    async def test_changed_remote_file_is_not_written_and_collection_is_incomplete(self):
        remote = FakeAFC()
        path = f"/Documents/LiveRelayDiagnostics/{RUN}.jsonl"
        remote.metadata_sequences[path] = [
            {"st_ifmt": "S_IFREG", "st_size": len(remote.contents[path]), "st_mtime": 1},
            {"st_ifmt": "S_IFREG", "st_size": len(remote.contents[path]), "st_mtime": 2}]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            report = await collector.collect(remote, output)
            self.assertFalse(report["collection_complete"])
            self.assertEqual(len(report["errors"]), 1)
            self.assertFalse((output / path.lstrip("/")).exists())

    async def test_remote_size_mismatch_is_rejected(self):
        remote = FakeAFC()
        path = f"/Documents/LiveRelayDiagnostics/{RUN}.jsonl"
        remote.metadata_sequences[path] = [{"st_ifmt": "S_IFREG", "st_size": 999, "st_mtime": 1}]
        with tempfile.TemporaryDirectory() as temporary:
            report = await collector.collect(remote, Path(temporary))
            self.assertFalse(report["collection_complete"])

    async def test_existing_different_bytes_are_preserved_and_same_bytes_are_reused(self):
        remote = FakeAFC()
        path = f"/Documents/LiveRelayDiagnostics/{RUN}.jsonl"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            destination = output / path.lstrip("/")
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"DO NOT REPLACE")
            result = await collector.collect(remote, output)
            self.assertFalse(result["collection_complete"])
            self.assertEqual(destination.read_bytes(), b"DO NOT REPLACE")
            destination.write_bytes(remote.contents[path])
            result = await collector.collect(remote, output)
            self.assertTrue(result["collection_complete"])
            entry = next(record for record in result["files"] if record["remote_path"] == path)
            self.assertTrue(entry["reused_identical_file"])

    async def test_remote_symlink_is_never_read(self):
        remote = FakeAFC()
        path = f"/Documents/LiveRelayDiagnostics/{RUN}.jsonl"
        remote.metadata_sequences[path] = [{"st_ifmt": "S_IFLNK", "st_size": 8, "st_mtime": 1}]
        with tempfile.TemporaryDirectory() as temporary:
            report = await collector.collect(remote, Path(temporary))
            self.assertFalse(report["collection_complete"])
            self.assertNotIn(path, remote.reads)

    async def test_missing_groups_with_no_diagnostics_are_not_success(self):
        remote = FakeAFC()
        remote.directories["/Documents"] = []
        with tempfile.TemporaryDirectory() as temporary:
            report = await collector.collect(remote, Path(temporary))
            self.assertFalse(report["collection_complete"])
            self.assertEqual(report["files"], [])
            self.assertEqual(len(report["missing_groups"]), 3)

    def test_help_does_not_need_phone_sdk_or_contact_a_device(self):
        process = subprocess.run([sys.executable, "tools/collect_iphone_diagnostics.py", "--help"],
                                 capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(process.returncode, 0, process.stderr)
        for option in ("--udid", "--bundle", "--output"):
            self.assertIn(option, process.stdout)


if __name__ == "__main__":
    unittest.main()
