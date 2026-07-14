#!/usr/bin/env python3
"""Validate candidate-specific manual release acceptance evidence.

This intentionally uses only the Python standard library so the protected
release gate does not need to download or execute a schema validator.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path, PurePath
from typing import Any


REQUIRED_CHECKS = (
    "disposable_workspace",
    "input_sources_installed",
    "performance_budgets_recorded",
    "dead_key",
    "emoji",
    "japanese_romaji",
    "simplified_chinese_pinyin",
    "korean_2_set",
    "voiceover",
    "five_minute_redraw_search",
    "main_thread_filesystem_stress",
    "open_edit_save_reopen",
    "quit_modified_buffer_matrix",
    "sidebar_operations_and_error_recovery",
    "sidebar_layout_state_preserved",
    "quick_open_and_editor_chrome",
    "reduce_motion_and_appearance",
)

STATUS_VALUES = {"PASS", "FAIL", "BLOCKED", "NOT RUN"}
PLACEHOLDER_VALUES = {
    "",
    "PASS",
    "FAIL",
    "BLOCKED",
    "NOT RUN",
    "TODO",
    "TBD",
    "N/A",
    "NONE",
    "UNKNOWN",
}
TOP_LEVEL_KEYS = {
    "$schema",
    "schema_version",
    "candidate",
    "tester",
    "evidence_root",
    "performance",
    "checks",
    "decision",
}


def _is_mapping(value: Any) -> bool:
    return isinstance(value, dict)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_complete_string(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    stripped = value.strip()
    return stripped.upper() not in PLACEHOLDER_VALUES and not (
        stripped.startswith("__") and stripped.endswith("__")
    )


def _require_keys(
    value: Any,
    path: str,
    required: set[str],
    allowed: set[str],
    errors: list[str],
) -> bool:
    if not _is_mapping(value):
        errors.append(f"{path} must be an object")
        return False
    missing = sorted(required - set(value))
    unexpected = sorted(set(value) - allowed)
    for key in missing:
        errors.append(f"{path}.{key} is required")
    for key in unexpected:
        errors.append(f"{path}.{key} is not allowed")
    return not missing


def _require_complete_string(value: Any, path: str, errors: list[str]) -> None:
    if not _is_complete_string(value):
        errors.append(f"{path} must be a non-placeholder string")


def _require_timestamp(value: Any, path: str, errors: list[str]) -> None:
    if not _is_complete_string(value):
        errors.append(f"{path} must be an ISO-8601 timestamp with a timezone")
        return
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        errors.append(f"{path} must be an ISO-8601 timestamp with a timezone")
        return
    if parsed.tzinfo is None:
        errors.append(f"{path} must include a timezone")


def _require_nonnegative_number(value: Any, path: str, errors: list[str]) -> None:
    if not _is_number(value) or value < 0:
        errors.append(f"{path} must be a non-negative number")


def _require_positive_number(value: Any, path: str, errors: list[str]) -> None:
    if not _is_number(value) or value <= 0:
        errors.append(f"{path} must be a positive number")


def _validate_evidence(value: Any, path: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value:
        errors.append(f"{path} must contain at least one evidence reference")
        return
    for index, reference in enumerate(value):
        _require_complete_string(reference, f"{path}[{index}]", errors)


def _validate_candidate(
    candidate: Any,
    expected_tag: str,
    expected_commit: str,
    expected_artifact: str,
    expected_sha256: str,
    errors: list[str],
) -> None:
    keys = {
        "tag",
        "commit_sha",
        "artifact_filename",
        "archive_sha256",
        "architecture",
        "packaged_neovim_version",
    }
    if not _require_keys(candidate, "candidate", keys, keys, errors):
        return

    for key in keys:
        _require_complete_string(candidate.get(key), f"candidate.{key}", errors)

    tag = candidate.get("tag")
    commit = candidate.get("commit_sha")
    artifact = candidate.get("artifact_filename")
    sha256 = candidate.get("archive_sha256")

    if tag != expected_tag:
        errors.append(f"candidate.tag does not match expected tag {expected_tag!r}")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        errors.append("candidate.commit_sha must be a full lowercase 40-character Git SHA")
    elif commit != expected_commit:
        errors.append("candidate.commit_sha does not match the workflow commit")
    if artifact != expected_artifact:
        errors.append(f"candidate.artifact_filename does not match {expected_artifact!r}")
    if isinstance(artifact, str) and PurePath(artifact).name != artifact:
        errors.append("candidate.artifact_filename must be a filename, not a path")
    if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        errors.append("candidate.archive_sha256 must be a lowercase 64-character SHA-256")
    elif sha256 != expected_sha256:
        errors.append("candidate.archive_sha256 does not match the downloaded artifact")
    if candidate.get("architecture") != "arm64":
        errors.append("candidate.architecture must be arm64")


def _validate_tester(tester: Any, errors: list[str]) -> None:
    keys = {
        "name",
        "tested_at",
        "macos_version_build",
        "hardware",
        "display",
        "input_sources",
    }
    if not _require_keys(tester, "tester", keys, keys, errors):
        return
    for key in ("name", "macos_version_build", "hardware", "display"):
        _require_complete_string(tester.get(key), f"tester.{key}", errors)
    _require_timestamp(tester.get("tested_at"), "tester.tested_at", errors)
    input_sources = tester.get("input_sources")
    if not isinstance(input_sources, list) or len(input_sources) < 3:
        errors.append("tester.input_sources must name at least three installed IME sources")
    else:
        for index, source in enumerate(input_sources):
            _require_complete_string(source, f"tester.input_sources[{index}]", errors)


def _validate_performance(performance: Any, errors: list[str]) -> None:
    sections = {"redraw_search", "filesystem_stress"}
    if not _require_keys(performance, "performance", sections, sections, errors):
        return

    redraw_keys = {
        "duration_seconds",
        "sample_count",
        "rss_growth_budget_mib",
        "observed_rss_growth_mib",
        "unresponsive_budget_ms",
        "observed_max_unresponsive_ms",
    }
    redraw = performance.get("redraw_search")
    if _require_keys(redraw, "performance.redraw_search", redraw_keys, redraw_keys, errors):
        duration = redraw.get("duration_seconds")
        samples = redraw.get("sample_count")
        if not _is_number(duration) or duration < 300:
            errors.append("performance.redraw_search.duration_seconds must be at least 300")
        if not isinstance(samples, int) or isinstance(samples, bool) or samples < 7:
            errors.append("performance.redraw_search.sample_count must be at least 7")
        for key in ("rss_growth_budget_mib", "unresponsive_budget_ms"):
            _require_positive_number(redraw.get(key), f"performance.redraw_search.{key}", errors)
        for key in ("observed_rss_growth_mib", "observed_max_unresponsive_ms"):
            _require_nonnegative_number(redraw.get(key), f"performance.redraw_search.{key}", errors)
        budget = redraw.get("rss_growth_budget_mib")
        observed = redraw.get("observed_rss_growth_mib")
        if _is_number(budget) and _is_number(observed) and budget > 0 and observed > budget:
            errors.append("performance.redraw_search observed RSS growth exceeds its budget")
        budget = redraw.get("unresponsive_budget_ms")
        observed = redraw.get("observed_max_unresponsive_ms")
        if _is_number(budget) and _is_number(observed) and budget > 0 and observed > budget:
            errors.append("performance.redraw_search observed unresponsive interval exceeds its budget")

    filesystem_keys = {
        "file_count",
        "mutation_count",
        "stall_budget_ms",
        "observed_max_stall_ms",
    }
    filesystem = performance.get("filesystem_stress")
    if _require_keys(
        filesystem,
        "performance.filesystem_stress",
        filesystem_keys,
        filesystem_keys,
        errors,
    ):
        file_count = filesystem.get("file_count")
        mutation_count = filesystem.get("mutation_count")
        if not isinstance(file_count, int) or isinstance(file_count, bool) or file_count < 50_000:
            errors.append("performance.filesystem_stress.file_count must be at least 50000")
        if (
            not isinstance(mutation_count, int)
            or isinstance(mutation_count, bool)
            or mutation_count < 500
        ):
            errors.append("performance.filesystem_stress.mutation_count must be at least 500")
        _require_positive_number(
            filesystem.get("stall_budget_ms"),
            "performance.filesystem_stress.stall_budget_ms",
            errors,
        )
        _require_nonnegative_number(
            filesystem.get("observed_max_stall_ms"),
            "performance.filesystem_stress.observed_max_stall_ms",
            errors,
        )
        budget = filesystem.get("stall_budget_ms")
        observed = filesystem.get("observed_max_stall_ms")
        if _is_number(budget) and _is_number(observed) and budget > 0 and observed > budget:
            errors.append("performance.filesystem_stress observed stall exceeds its budget")


def _validate_checks(checks: Any, errors: list[str]) -> None:
    required = set(REQUIRED_CHECKS)
    if not _require_keys(checks, "checks", required, required, errors):
        return
    item_keys = {"status", "evidence", "notes"}
    for name in REQUIRED_CHECKS:
        item = checks.get(name)
        path = f"checks.{name}"
        if not _require_keys(item, path, {"status", "evidence"}, item_keys, errors):
            continue
        status = item.get("status")
        if status not in STATUS_VALUES:
            errors.append(f"{path}.status must be one of {sorted(STATUS_VALUES)}")
        elif status != "PASS":
            errors.append(f"{path}.status is {status!r}; every required check must PASS")
        _validate_evidence(item.get("evidence"), f"{path}.evidence", errors)
        if "notes" in item and not isinstance(item["notes"], str):
            errors.append(f"{path}.notes must be a string")


def _validate_decision(decision: Any, errors: list[str]) -> None:
    keys = {"status", "release_owner", "signed_off_at", "evidence", "blocking_issues"}
    if not _require_keys(decision, "decision", keys, keys, errors):
        return
    status = decision.get("status")
    if status not in STATUS_VALUES:
        errors.append(f"decision.status must be one of {sorted(STATUS_VALUES)}")
    elif status != "PASS":
        errors.append(f"decision.status is {status!r}; the release decision must PASS")
    _require_complete_string(decision.get("release_owner"), "decision.release_owner", errors)
    _require_timestamp(decision.get("signed_off_at"), "decision.signed_off_at", errors)
    _validate_evidence(decision.get("evidence"), "decision.evidence", errors)
    blocking = decision.get("blocking_issues")
    if not isinstance(blocking, list):
        errors.append("decision.blocking_issues must be an array")
    elif blocking:
        errors.append("decision.blocking_issues must be empty for an accepted release")


def validate_record(
    record: Any,
    *,
    expected_tag: str,
    expected_commit: str,
    expected_artifact: str,
    expected_sha256: str,
) -> list[str]:
    errors: list[str] = []
    required = TOP_LEVEL_KEYS - {"$schema"}
    if not _require_keys(record, "record", required, TOP_LEVEL_KEYS, errors):
        return errors
    if record.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    _validate_candidate(
        record.get("candidate"),
        expected_tag,
        expected_commit,
        expected_artifact,
        expected_sha256,
        errors,
    )
    _validate_tester(record.get("tester"), errors)
    _require_complete_string(record.get("evidence_root"), "evidence_root", errors)
    _validate_performance(record.get("performance"), errors)
    _validate_checks(record.get("checks"), errors)
    _validate_decision(record.get("decision"), errors)
    return errors


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--sha256", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        with args.record.open("r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"release acceptance record could not be read: {error}", file=sys.stderr)
        return 2

    errors = validate_record(
        record,
        expected_tag=args.tag,
        expected_commit=args.commit,
        expected_artifact=args.artifact,
        expected_sha256=args.sha256,
    )
    if errors:
        print("release acceptance validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "RELEASE ACCEPTANCE OK: "
        f"{args.tag} {args.commit} {args.artifact} sha256={args.sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
