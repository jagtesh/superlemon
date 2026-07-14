#!/usr/bin/env python3

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-release-acceptance.py"
TEMPLATE = ROOT / "packaging" / "RELEASE_ACCEPTANCE.json"
SCHEMA = ROOT / "packaging" / "release-acceptance.schema.json"

SPEC = importlib.util.spec_from_file_location("release_acceptance_validator", VALIDATOR)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR_MODULE)
REQUIRED_CHECKS = VALIDATOR_MODULE.REQUIRED_CHECKS

TAG = "v1.2.3"
COMMIT = "a" * 40
ARTIFACT = "Superlemon-1.2.3-macOS-arm64-unsigned.zip"
DIGEST = "b" * 64


def complete_record():
    return {
        "$schema": "./release-acceptance.schema.json",
        "schema_version": 1,
        "candidate": {
            "tag": TAG,
            "commit_sha": COMMIT,
            "artifact_filename": ARTIFACT,
            "archive_sha256": DIGEST,
            "architecture": "arm64",
            "packaged_neovim_version": "0.12.4",
        },
        "tester": {
            "name": "Release Tester",
            "tested_at": "2026-07-13T02:00:00-04:00",
            "macos_version_build": "macOS 15.5 (24F74)",
            "hardware": "Mac mini M4, 16 GB",
            "display": "2560x1440 at 60 Hz",
            "input_sources": [
                "Japanese - Romaji",
                "Simplified Chinese - Pinyin",
                "Korean - 2-Set",
            ],
        },
        "evidence_root": "https://example.invalid/releases/v1.2.3/acceptance/",
        "performance": {
            "redraw_search": {
                "duration_seconds": 300,
                "sample_count": 7,
                "rss_growth_budget_mib": 128,
                "observed_rss_growth_mib": 24.5,
                "unresponsive_budget_ms": 250,
                "observed_max_unresponsive_ms": 42,
            },
            "filesystem_stress": {
                "file_count": 50_000,
                "mutation_count": 500,
                "stall_budget_ms": 250,
                "observed_max_stall_ms": 31,
            },
        },
        "checks": {
            name: {
                "status": "PASS",
                "evidence": [f"evidence/{name}.txt"],
                "notes": "Verified against the candidate archive.",
            }
            for name in REQUIRED_CHECKS
        },
        "decision": {
            "status": "PASS",
            "release_owner": "Release Owner",
            "signed_off_at": "2026-07-13T03:00:00-04:00",
            "evidence": ["evidence/release-signoff.txt"],
            "blocking_issues": [],
        },
    }


class ReleaseAcceptanceValidatorTests(unittest.TestCase):
    def run_validator(self, record, **expected_overrides):
        expected = {
            "tag": TAG,
            "commit": COMMIT,
            "artifact": ARTIFACT,
            "sha256": DIGEST,
        }
        expected.update(expected_overrides)
        with tempfile.TemporaryDirectory() as directory:
            record_path = Path(directory) / "acceptance.json"
            record_path.write_text(json.dumps(record), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    "--record",
                    str(record_path),
                    "--tag",
                    expected["tag"],
                    "--commit",
                    expected["commit"],
                    "--artifact",
                    expected["artifact"],
                    "--sha256",
                    expected["sha256"],
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_complete_candidate_specific_record_passes(self):
        result = self.run_validator(complete_record())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RELEASE ACCEPTANCE OK", result.stdout)

    def test_checked_in_not_run_template_cannot_pass(self):
        result = self.run_validator(json.loads(TEMPLATE.read_text(encoding="utf-8")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("every required check must PASS", result.stderr)
        self.assertIn("does not match expected tag", result.stderr)

    def test_template_schema_and_validator_require_the_same_checks(self):
        template = json.loads(TEMPLATE.read_text(encoding="utf-8"))
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        expected = set(REQUIRED_CHECKS)
        self.assertEqual(set(template["checks"]), expected)
        self.assertEqual(set(schema["properties"]["checks"]["required"]), expected)
        self.assertEqual(set(schema["properties"]["checks"]["properties"]), expected)

    def test_all_nonpassing_statuses_are_rejected(self):
        for status in ("NOT RUN", "BLOCKED", "FAIL"):
            with self.subTest(status=status):
                record = complete_record()
                record["checks"]["dead_key"]["status"] = status
                result = self.run_validator(record)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"status is '{status}'", result.stderr)

    def test_nonpassing_overall_decision_is_rejected(self):
        record = complete_record()
        record["decision"]["status"] = "BLOCKED"
        result = self.run_validator(record)
        self.assertEqual(result.returncode, 1)
        self.assertIn("release decision must PASS", result.stderr)

    def test_missing_check_and_unexpected_check_are_rejected(self):
        record = complete_record()
        del record["checks"]["voiceover"]
        record["checks"]["invented_check"] = {
            "status": "PASS",
            "evidence": ["evidence/invented.txt"],
        }
        result = self.run_validator(record)
        self.assertEqual(result.returncode, 1)
        self.assertIn("checks.voiceover is required", result.stderr)
        self.assertIn("checks.invented_check is not allowed", result.stderr)

    def test_empty_or_placeholder_evidence_is_rejected(self):
        for evidence in ([], [""], ["NOT RUN"], ["TODO"]):
            with self.subTest(evidence=evidence):
                record = complete_record()
                record["checks"]["emoji"]["evidence"] = evidence
                result = self.run_validator(record)
                self.assertEqual(result.returncode, 1)
                self.assertIn("checks.emoji.evidence", result.stderr)

    def test_candidate_binding_rejects_each_metadata_mismatch(self):
        cases = {
            "tag": {"tag": "v9.9.9"},
            "commit": {"commit": "c" * 40},
            "artifact": {"artifact": "different.zip"},
            "digest": {"sha256": "d" * 64},
        }
        for name, overrides in cases.items():
            with self.subTest(field=name):
                result = self.run_validator(complete_record(), **overrides)
                self.assertEqual(result.returncode, 1)

    def test_performance_minimums_and_budgets_are_enforced(self):
        record = complete_record()
        record["performance"]["redraw_search"]["duration_seconds"] = 299
        record["performance"]["redraw_search"]["observed_rss_growth_mib"] = 129
        record["performance"]["filesystem_stress"]["file_count"] = 49_999
        record["performance"]["filesystem_stress"]["observed_max_stall_ms"] = 251
        result = self.run_validator(record)
        self.assertEqual(result.returncode, 1)
        self.assertIn("duration_seconds must be at least 300", result.stderr)
        self.assertIn("observed RSS growth exceeds its budget", result.stderr)
        self.assertIn("file_count must be at least 50000", result.stderr)
        self.assertIn("observed stall exceeds its budget", result.stderr)

    def test_timestamps_require_timezones_and_signoff_requires_no_blockers(self):
        record = complete_record()
        record["tester"]["tested_at"] = "2026-07-13T02:00:00"
        record["decision"]["blocking_issues"] = ["https://example.invalid/issue/1"]
        result = self.run_validator(record)
        self.assertEqual(result.returncode, 1)
        self.assertIn("tester.tested_at must include a timezone", result.stderr)
        self.assertIn("blocking_issues must be empty", result.stderr)

    def test_malformed_json_is_a_read_error(self):
        with tempfile.TemporaryDirectory() as directory:
            record_path = Path(directory) / "acceptance.json"
            record_path.write_text("{not json", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    "--record",
                    str(record_path),
                    "--tag",
                    TAG,
                    "--commit",
                    COMMIT,
                    "--artifact",
                    ARTIFACT,
                    "--sha256",
                    DIGEST,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not be read", result.stderr)


if __name__ == "__main__":
    unittest.main()
