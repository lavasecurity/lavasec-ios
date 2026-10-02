"""Offline authoring-contract tests. No provider, ffmpeg, credentials or clips required."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-explore-narration.py"
spec = importlib.util.spec_from_file_location("narration_generator", SCRIPT)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class NarrationGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.script = self.root / "script.json"
        self.output = self.root / "pack"
        self.document = {"schema": 1, "approved": True, "model": "qwen/test-snapshot", "voice": "test-voice", "revision": "approved-copy-rev-1",
                         "scenes": [{"id": "device", "locales": {"en": "Your device.", "ja": "デバイス。"}}]}
        self.write_script()
        self.request = Mock(side_effect=self.response)
        self.convert = Mock(side_effect=self.conversion)

    def tearDown(self):
        self.temp.cleanup()

    def write_script(self):
        self.script.write_text(json.dumps(self.document), encoding="utf-8")

    def response(self, url, payload, key, limit):
        if payload is None:
            return {"content-type": "application/json"}, json.dumps({"data": [{"id": "qwen/test-snapshot", "canonical_slug": "qwen/test-snapshot"}]}).encode()
        return {"content-type": "audio/pcm;rate=24000;channels=1", "x-generation-id": "gen-test"}, b"\x00\x00\x00\x00"

    def conversion(self, source, target, master=None):
        self.assertFalse(self.output.exists(), "No partial pack may be visible")
        self.assertEqual(source.suffix, ".pcm")
        self.assertEqual(target.suffix, ".caf")
        target.write_bytes(b"offline-converted-fixture")
        return 2.5

    def generate(self, **overrides):
        kwargs = {"api_key": "offline-fixture-key", "request": self.request, "convert": self.convert}
        kwargs.update(overrides)
        revision = kwargs.pop("revision", "approved-copy-rev-1")
        return generator.generate(self.script, self.output, "qwen/test-snapshot", "test-voice", revision, **kwargs)

    def test_approved_complete_pack_is_atomically_published(self):
        result = self.generate()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(result, manifest)
        self.assertEqual(len(manifest["clips"]), 2)
        self.assertFalse(manifest["listeningQualified"])
        for clip in manifest["clips"]:
            self.assertEqual(clip["sha256"], generator.hashlib.sha256((self.output / clip["file"]).read_bytes()).hexdigest())
            self.assertEqual(clip["generationID"], "gen-test")
            self.assertEqual(clip["revision"], "approved-copy-rev-1")
            self.assertEqual(clip["codec"], "opus")
            self.assertEqual(clip["container"], "caf")
            self.assertTrue(clip["approved"])
            self.assertTrue(clip["file"].endswith(".caf"))
        self.assertEqual(self.request.call_args_list[0].args[0], generator.BASE + "/models?output_modalities=speech")
        self.assertEqual(self.request.call_args_list[1].args[1]["response_format"], "pcm")
        self.assertNotIn("offline-fixture-key", (self.output / "manifest.json").read_text())
        self.assertTrue(str(self.convert.call_args_list[0].args[2]).endswith("sources/device.en.flac"))

    def test_per_locale_voice_override_is_used_for_its_locale(self):
        self.document["voices"] = {"ja": {"model": "qwen/other", "voice": "ja-voice"}}
        self.write_script()
        with patch.object(generator, "verify_model", return_value={"id": "x"}):
            self.generate()
        audio = [c for c in self.request.call_args_list if isinstance(c.args[1], dict) and c.args[1].get("voice")]
        ja = next(c for c in audio if c.args[1].get("input") == "デバイス。")
        en = next(c for c in audio if c.args[1].get("input") == "Your device.")
        self.assertEqual(ja.args[1]["model"], "qwen/other")
        self.assertEqual(ja.args[1]["voice"], "ja-voice")
        self.assertEqual(en.args[1]["model"], "qwen/test-snapshot")

    def test_unapproved_script_fails_before_network(self):
        self.document["approved"] = False
        self.write_script()
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.request.assert_not_called()

    def test_missing_key_fails_before_network(self):
        with self.assertRaises(generator.GenerationError):
            self.generate(api_key="")
        self.request.assert_not_called()

    def test_audio_approval_cannot_be_overridden_by_text_approval(self):
        self.document["metadata"] = {"audioGenerationApproved": False}
        self.write_script()
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.request.assert_not_called()

    def test_voice_must_match_approved_script(self):
        self.document["voice"] = "different"
        self.write_script()
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.request.assert_not_called()

    def test_revision_must_match_approved_script(self):
        with self.assertRaises(generator.GenerationError):
            self.generate(revision="unapproved-copy-rev")
        self.request.assert_not_called()

    def test_existing_pack_is_preserved(self):
        self.output.mkdir()
        marker = self.output / "manifest.json"
        marker.write_text("existing")
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.assertEqual(marker.read_text(), "existing")
        self.request.assert_not_called()

    def test_invalid_audio_type_aborts_entire_pack(self):
        self.request.side_effect = [self.response("", None, "", 0), ({"content-type": "audio/pcm"}, b"first!"),
                                    ({"content-type": "application/json"}, b'{"error":"do not save"}')]
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".explore-narration-*")), [])

    def test_empty_audio_never_reaches_converter(self):
        self.request.side_effect = [self.response("", None, "", 0), ({"content-type": "audio/pcm"}, b"")]
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.convert.assert_not_called()

    def test_provider_pcm_rate_mismatch_is_rejected(self):
        self.request.side_effect = [self.response("", None, "", 0),
                                    ({"content-type": "audio/pcm;rate=16000;channels=1"}, b"\x00\x00")]
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.convert.assert_not_called()

    def test_missing_model_never_generates_audio(self):
        self.request.side_effect = None
        self.request.return_value = ({"content-type": "application/json"}, b'{"data":[]}')
        with self.assertRaises(generator.GenerationError):
            self.generate()
        self.assertEqual(self.request.call_count, 1)

    def test_invalid_ids_duplicates_and_incomplete_locales_are_rejected(self):
        cases = [
            [{"id": "../escape", "locales": {"en": "Text"}}],
            [{"id": "same", "locales": {"en": "Text"}}, {"id": "same", "locales": {"en": "Text"}}],
            [{"id": "a", "locales": {"en": "Text"}}, {"id": "b", "locales": {"ja": "Text"}}],
        ]
        for scenes in cases:
            with self.subTest(scenes=scenes):
                self.document["scenes"] = scenes
                self.write_script()
                with self.assertRaises(generator.GenerationError):
                    self.generate()
        self.request.assert_not_called()

    def test_converter_verifies_duration_and_does_not_inherit_key(self):
        source, target = self.root / "source.pcm", self.root / "target.caf"
        source.write_bytes(b"\x00\x00\x00\x00")
        target.write_bytes(b"fixture")
        run = Mock(return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({
            "format": {"format_name": "caf", "duration": "2.5"},
            "streams": [{"codec_name": "opus", "channels": 1}]}).encode()))
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": "do-not-inherit"}):
            self.assertEqual(generator.render_audio(source, target, None, run), 2.5)
        for call in run.call_args_list:
            self.assertNotIn("OPENROUTER_API_KEY", call.kwargs["env"])
        self.assertIn("-f", run.call_args_list[0].args[0])
        self.assertIn("s16le", run.call_args_list[0].args[0])
        self.assertIn("libopus", run.call_args_list[0].args[0])
        self.assertIn("caf", run.call_args_list[0].args[0])
        for duration in ["NaN", "0", "30.01"]:
            run.return_value.stdout = json.dumps({"format": {"format_name": "caf", "duration": duration},
                                                  "streams": [{"codec_name": "opus", "channels": 1}]}).encode()
            with self.assertRaises(generator.GenerationError):
                generator.render_audio(source, target, None, run)

    def test_non_opus_or_non_caf_conversion_is_rejected(self):
        source, target = self.root / "source.pcm", self.root / "target.caf"
        source.write_bytes(b"\x00\x00\x00\x00")
        target.write_bytes(b"fixture")
        for format_name, codec in [("mp4", "opus"), ("caf", "aac"), ("ogg", "opus")]:
            run = Mock(return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({
                "format": {"format_name": format_name, "duration": "2.5"},
                "streams": [{"codec_name": codec, "channels": 1}]}).encode()))
            with self.assertRaises(generator.GenerationError):
                generator.render_audio(source, target, None, run)

    def test_master_is_written_when_provided(self):
        source, target = self.root / "source.pcm", self.root / "target.caf"
        master = self.root / "master.flac"
        source.write_bytes(b"\x00\x00\x00\x00")
        target.write_bytes(b"fixture")
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            if "ffprobe" in cmd[0]:
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps({
                    "format": {"format_name": "caf", "duration": "2.5"},
                    "streams": [{"codec_name": "opus", "channels": 1}]}).encode())
            return subprocess.CompletedProcess(cmd, 0, stdout=b"")

        self.assertEqual(generator.render_audio(source, target, master, run), 2.5)
        self.assertTrue(any("flac" in token for token in calls[0]), calls[0])
        self.assertTrue(any("libopus" in token for token in calls[1]), calls[1])

    def test_http_failure_never_exposes_provider_error_body(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(generator.BASE, 401, "key-secret", {}, io.BytesIO(b"key-secret"))
        with patch.object(generator.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(generator.GenerationError) as caught:
                generator.http_request(generator.BASE, {}, "key-secret", 100)
        self.assertNotIn("key-secret", str(caught.exception))
        self.assertIn("401", str(caught.exception))

    def test_transport_stops_at_bounded_size(self):
        response = Mock(status=200, headers={"content-type": "audio/pcm"})
        response.read.side_effect = [b"01234567890"]
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        opener = Mock()
        opener.open.return_value = response
        with patch.object(generator.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(generator.GenerationError):
                generator.http_request(generator.BASE, {}, "key-secret", 10)


if __name__ == "__main__":
    unittest.main()
