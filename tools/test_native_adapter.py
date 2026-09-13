#!/usr/bin/env python3
"""Hermetic adapters/CLI regression tests; no microphone, keys, or cloud calls."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import types
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("RAPPVOICE_TEST_CLI", str(ROOT / "native/.build/debug/RAPPVoice")))


class BasicAgent:
    def __init__(self, *_args):
        pass


stub = types.ModuleType("agents.basic_agent")
stub.BasicAgent = BasicAgent
sys.modules["agents"] = types.ModuleType("agents")
sys.modules["agents.basic_agent"] = stub


def load_adapter(relative):
    spec = importlib.util.spec_from_file_location("fixture_" + str(uuid.uuid4()).replace("-", ""), ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ADAPTERS = [
    load_adapter("rapp_voice/singleton/rapp_voice_agent.py"),
    load_adapter("rapp_voice/twin/agents/rapp_voice_agent.py"),
]


class AdapterTests(unittest.TestCase):
    def test_integration_copy_distinguishes_native_engine_from_host_chat(self):
        ui = (ROOT / "rapp_voice/ui/index.html").read_text()
        soul = (ROOT / "rapp_voice/twin/soul.md").read_text()
        self.assertIn("bundled whisper-cli", ui)
        self.assertIn("conversation model may be remote", ui)
        self.assertIn("Prefer the installed", soul)
        self.assertNotIn("Speech recognition is whisper.cpp on localhost", soul)

    def test_shipped_polish_hook_keeps_transcript_out_of_argv(self):
        directory = ROOT / "native/.build/hook-tests" / str(uuid.uuid4())
        home = directory / "home"
        binary = home / ".local/bin/claude"
        transcript = directory / "transcript.txt"
        arguments = directory / "arguments.txt"
        standard_input = directory / "stdin.txt"
        try:
            binary.parent.mkdir(parents=True)
            transcript.parent.mkdir(parents=True, exist_ok=True)
            transcript.write_text("sensitive fixture transcript", encoding="utf-8")
            binary.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" > \"$VOICE_TEST_ARGS\"\n"
                "cat > \"$VOICE_TEST_STDIN\"\n"
                "printf 'cleaned fixture\\n'\n",
                encoding="utf-8",
            )
            binary.chmod(0o700)
            result = subprocess.run(
                [str(ROOT / "polish.sh"), str(transcript)],
                capture_output=True, text=True, timeout=10,
                env=dict(os.environ, HOME=str(home), VOICE_TEST_ARGS=str(arguments),
                         VOICE_TEST_STDIN=str(standard_input)),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "cleaned fixture\n")
            self.assertNotIn(transcript.read_text(), arguments.read_text())
            self.assertEqual(standard_input.read_text(), transcript.read_text())
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_native_dispatch_uses_typed_stdin_and_no_lua(self):
        for module in ADAPTERS:
            payload = 'quotes " and [==[ and ]==] and \n not code'
            response = json.dumps({"ok": True, "runtime": "native", "action": "process", "text": "safe result"})
            with patch.object(module, "_native", return_value="/fixture/RAPPVoice"), \
                    patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, response)) as run, \
                    patch.object(module, "_hs", side_effect=AssertionError("legacy called")):
                result = module.RappVoiceAgent().perform(action="process", text=payload, app="Terminal")
                self.assertEqual(result, "safe result")
                args, kwargs = run.call_args
                self.assertEqual(args[0], ["/fixture/RAPPVoice", "--action"])
                self.assertEqual(json.loads(kwargs["input"])["text"], payload)
                self.assertNotIn("shell", kwargs)

    def test_native_failure_does_not_repeat_side_effects_in_legacy(self):
        for module in ADAPTERS:
            with patch.object(module, "_native", return_value="/fixture/RAPPVoice"), \
                    patch.object(module.subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 30)), \
                    patch.object(module.RappVoiceAgent, "_add_term", side_effect=AssertionError("duplicate fallback write")):
                result = module.RappVoiceAgent().perform(action="add_term", term="OpenRappter")
                self.assertIn("Legacy fallback was not invoked", result)

    def test_invalid_response_does_not_claim_success(self):
        for module in ADAPTERS:
            with patch.object(module, "_native", return_value="/fixture/RAPPVoice"), \
                    patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"text":"false success"}')):
                result = module.RappVoiceAgent().perform(action="doctor")
                self.assertIn("Invalid native response", result)

    def test_legacy_fallback_is_preserved_only_if_native_absent(self):
        for module in ADAPTERS:
            with patch.dict(os.environ, {}, clear=True), patch.object(module, "_native", return_value=None), \
                    patch.object(module.RappVoiceAgent, "_doctor", return_value="legacy doctor") as legacy:
                self.assertEqual(module.RappVoiceAgent().perform(action="doctor"), "legacy doctor")
                legacy.assert_called_once()

    def test_actions_are_not_extended_to_capture_or_shell(self):
        for module in ADAPTERS:
            with patch.object(module, "_native", side_effect=AssertionError("should reject before dispatch")):
                self.assertIn("unknown action", module.RappVoiceAgent().perform(action="record"))
                self.assertIn("unknown action", module.RappVoiceAgent().perform(action="shell"))


@unittest.skipUnless(BINARY.is_file(), "Build RAPPVoice with swift test -j 2 first")
class NativeCLITests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / "native/.build/adapter-tests" / str(uuid.uuid4())
        self.directory.mkdir(parents=True)
        self.environment = dict(os.environ, RAPPVOICE_HOME=str(self.directory / "legacy"),
                                RAPPVOICE_NATIVE_HOME=str(self.directory / "native"),
                                RAPP_RUNTIME_BIN=str(self.directory / "missing-runtime"))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def action(self, request, expected_code=0):
        result = subprocess.run([str(BINARY), "--action"], input=json.dumps(request), capture_output=True,
                                text=True, env=self.environment, timeout=30)
        self.assertEqual(result.returncode, expected_code, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def test_real_cli_formatting_dictionary_and_legacy_file_preservation(self):
        legacy = self.directory / "legacy"
        legacy.mkdir()
        sentinel = legacy / "existing-recording.wav"
        sentinel.write_bytes(b"not personal audio: preservation sentinel")
        self.assertTrue(self.action({"action": "add_term", "term": "OpenRappter"})["ok"])
        self.assertEqual(self.action({"action": "process", "text": "um hello openrappter", "app": "TextEdit"})["text"],
                         "Hello OpenRappter.")
        self.assertEqual(self.action({"action": "process", "text": "Git status.", "app": "Terminal"})["text"], "git status")
        self.assertEqual(self.action({"action": "dictionary"})["text"], "OpenRappter\n")
        self.assertEqual(sentinel.read_bytes(), b"not personal audio: preservation sentinel")
        self.assertFalse((self.directory / "native/Work").exists(), "CLI must not start capture")

    def test_real_cli_unknown_actions_and_malformed_requests_fail(self):
        self.assertFalse(self.action({"action": "record"}, 1)["ok"])
        self.assertFalse(self.action({"action": "process", "shell": "no"}, 1)["ok"])
        self.assertFalse(self.action({"action": "add_term", "term": "one\ntwo"}, 1)["ok"])

    def test_real_cli_doctor_does_not_record_or_download(self):
        response = self.action({"action": "doctor"})
        self.assertTrue(response["ok"])
        self.assertIn("Model installed: false", response["text"])
        self.assertIn("Optional polish: OFF", response["text"])
        self.assertFalse((self.directory / "native/Models").exists())
        self.assertFalse((self.directory / "native/Work").exists())

    def test_real_adapter_discovers_explicit_native_binary(self):
        for module in ADAPTERS:
            with patch.dict(os.environ, dict(self.environment, RAPPVOICE_NATIVE_CLI=str(BINARY))), \
                    patch.object(module, "_hs", side_effect=AssertionError("native must not call hs")):
                self.assertEqual(module.RappVoiceAgent().perform(action="process", text="um hello"), "Hello.")

    def test_real_cli_handles_large_bounded_stdin_without_truncation(self):
        text = "x" * 50000
        response = self.action({"action": "process", "text": text, "app": "Terminal"})
        self.assertEqual(response["text"], text)
        self.assertFalse(self.action({"action": "process", "text": "x" * 70000}, 1)["ok"])

    def test_version_command_does_not_launch_capture(self):
        result = subprocess.run([str(BINARY), "--version"], capture_output=True, text=True,
                                env=self.environment, timeout=30)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "RAPPVoice 1.1.1")
        self.assertFalse((self.directory / "native").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
