# Superlemon release acceptance record

This is the procedural results template, not evidence that any check has
passed. Copy it to the release issue or release evidence bundle, fill every
field, and retain the completed copy with the exact artifact under test. Do not
change a row from `NOT RUN` without attaching the named evidence.

Allowed status values are `PASS`, `FAIL`, `BLOCKED`, and `NOT RUN`. A release
cannot be accepted while any required row is `FAIL`, `BLOCKED`, or `NOT RUN`.

## Machine-enforced tag gate

The protected tag workflow does not infer manual acceptance from a green build
or from this Markdown file. Copy
[`RELEASE_ACCEPTANCE.json`](RELEASE_ACCEPTANCE.json), complete every field, and
retain its referenced recordings, traces, logs, and result files at the stated
`evidence_root`. The record format is defined by
[`release-acceptance.schema.json`](release-acceptance.schema.json).

The checked-in JSON is deliberately unfinished and cannot pass. For a tag, the
completed record must identify the exact tag, full commit SHA, downloaded
validation-archive filename, and SHA-256. Every required check and the overall
decision must be `PASS`, every check must name evidence, performance minimums
and predeclared budgets must be satisfied, timestamps must include a timezone,
and `blocking_issues` must be empty.

On the dedicated GUI runner, configure the protected `release-acceptance`
environment variable `SUPERLEMON_ACCEPTANCE_RECORD_PATH` to the absolute path
of that completed JSON file. Write the completed record only after testing the
artifact produced for the tag, then approve the protected job. The job copies
the record before validating it, binds that copy to the downloaded artifact,
and uploads the validated copy with the automated evidence. Missing, stale,
unfinished, blocked, or failing records make the job fail and prevent the
release job from starting.

The validator can also be run before approval:

```sh
python3 scripts/validate-release-acceptance.py \
  --record /absolute/path/to/completed-acceptance.json \
  --tag v0.2.0 \
  --commit FULL_40_CHARACTER_TAG_COMMIT_SHA \
  --artifact Superlemon-0.2.0-macOS-arm64-unsigned.zip \
  --sha256 ARCHIVE_SHA256
```

Main-branch GUI staging intentionally uploads unfinished JSON and Markdown
templates so test work can be prepared without pretending it is release
acceptance. Developer ID signing, signed-package smoke, notarization, stapling,
and Gatekeeper assessment happen afterward in the protected release job; those
automated results complete the final signed-artifact preconditions below.

## Release metadata

| Field | Result |
| --- | --- |
| Version/tag | `NOT RUN` |
| Commit SHA | `NOT RUN` |
| App archive filename | `NOT RUN` |
| Archive SHA-256 | `NOT RUN` |
| App code-signing identity | `NOT RUN` |
| Notarization submission ID | `NOT RUN` |
| Packaged Neovim version | `NOT RUN` |
| macOS version/build | `NOT RUN` |
| Mac model, CPU, and memory | `NOT RUN` |
| Display resolution/refresh rate | `NOT RUN` |
| Tester and date | `NOT RUN` |
| Evidence folder or URL | `NOT RUN` |

## Preconditions

Record the result and supporting log or screenshot for each row.

| Required check | Status | Evidence/notes |
| --- | --- | --- |
| Archive SHA-256 matches the published digest | `NOT RUN` | |
| `codesign --verify --deep --strict` succeeds | `NOT RUN` | |
| `spctl --assess --type execute` accepts the app | `NOT RUN` | |
| Stapled notarization validates | `NOT RUN` | |
| `scripts/verify-package.sh` succeeds | `NOT RUN` | |
| Clean HOME/XDG `--smoke` reaches runtime readiness and first flush | `NOT RUN` | |
| A disposable workspace and disposable test files are prepared | `NOT RUN` | |
| Input sources below are installed before testing begins | `NOT RUN` | |
| Performance budgets below are filled in before measurement | `NOT RUN` | |

## Text input and accessibility matrix

Run each case in Insert mode in a disposable UTF-8 file. Save, close, reopen,
and compare the resulting Unicode text. Exercise composition cancellation with
Escape as well as candidate commit. Attach a short screen recording or a result
file containing the exact committed code points.

| Required case | Procedure and expected result | Status | Evidence/notes |
| --- | --- | --- | --- |
| macOS dead key | With `ABC` or `ABC - Extended`, enter Option-E then `e` to produce `é`; cancel a second pending accent with Escape. The committed character appears once, cancellation inserts nothing, cursor/selection remain coherent, and the reopened file matches. | `NOT RUN` | |
| Emoji | Open the macOS Character Viewer, commit a multi-scalar emoji such as `👩🏽‍💻`, move across it, undo, redo, save, and reopen. There is no duplicate insertion, replacement corruption, or invalid UTF-8. | `NOT RUN` | |
| Japanese Romaji | Select Japanese - Romaji, type `nihongo`, convert to `日本語`, traverse candidates, commit, then repeat and cancel. Marked text and candidate placement follow the caret; only the selected candidate is committed. | `NOT RUN` | |
| Simplified Chinese Pinyin | Select Simplified Chinese - Pinyin, type `zhongwen`, choose `中文`, then repeat and cancel. Composition, candidate placement, selection, commit, and cancellation remain coherent. | `NOT RUN` | |
| Korean 2-Set | Select Korean - 2-Set, type `gksrmf` to compose `한글`, edit inside the active composition, commit, save, and reopen. Jamo combine once into the expected syllables without cursor drift. | `NOT RUN` | |
| VoiceOver | Enable VoiceOver, focus and interact with the editor, move by character and line, select text, type, undo, and change buffers. VoiceOver identifies the text area and announces value/selection changes for the exposed viewport without hanging or claiming unavailable full-buffer text. | `NOT RUN` | |

Record any input-method-specific failure with the active input-source name,
macOS build, reproduction text, and whether it affects marked text, candidate
position, local replacement, commit, cancellation, or later file contents.

## Five-minute redraw/search memory run

Use a release build and a file of at least 100,000 lines with a search term that
has many matches. Record both the Superlemon process and bundled Neovim helper.
Use Instruments Points of Interest plus Allocations, or attach equivalent
captures. The available signposts include `RPC Request`, `MessagePack Decode`,
`ModelApply`, `Rasterization`, `DisplayCommit`, `Writer Queue Depth`, and
`ScrollFrame`.

Set these budgets before starting; leaving either blank keeps this check
`NOT RUN`:

| Budget | Value |
| --- | --- |
| Maximum acceptable combined RSS after 30 seconds idle above start | `NOT RUN` MiB |
| Maximum acceptable main-thread unresponsive interval | `NOT RUN` ms |

For five uninterrupted minutes, alternate rapid search next/previous, Page
Up/Page Down, trackpad scrolling, window resizing, and toggling search
highlighting. Sample RSS at least once per minute, then stop input, wait 30
seconds, and take the idle sample.

| Measurement | Superlemon RSS MiB | Neovim RSS MiB | Notes |
| --- | ---: | ---: | --- |
| Start after workspace settles | `NOT RUN` | `NOT RUN` | |
| Minute 1 | `NOT RUN` | `NOT RUN` | |
| Minute 2 | `NOT RUN` | `NOT RUN` | |
| Minute 3 | `NOT RUN` | `NOT RUN` | |
| Minute 4 | `NOT RUN` | `NOT RUN` | |
| Minute 5 | `NOT RUN` | `NOT RUN` | |
| After 30 seconds idle | `NOT RUN` | `NOT RUN` | |

Pass only if the app remains responsive, visible rows remain authoritative,
search/navigation stay correct, no crash or data loss occurs, and both recorded
budgets are met. A repeatable upward trend or a budget miss is a failure even if
the process survives.

| Required check | Status | Evidence/notes |
| --- | --- | --- |
| Five-minute redraw/search run | `NOT RUN` | Instruments trace and RSS samples: |

## Main-thread filesystem stress

Use a disposable workspace containing at least 50,000 files across nested
directories. While recording Time Profiler and hangs, repeatedly change Quick
Open queries, expand/collapse large sidebar directories, and create, rename,
move, and remove at least 500 fixture files from a separate process so the file
watcher and index refresh concurrently. Do not run the mutation load against a
real project.

Set the maximum acceptable main-thread filesystem or indexing stall before the
run: `NOT RUN` ms. Leaving it blank keeps this check `NOT RUN`.

Pass only if typing, selection, and scrolling remain responsive; external
changes converge in the sidebar/index; no stale deleted result opens; no crash
or data loss occurs; and the recorded stall budget is met. Attach the Time
Profiler or hang trace and the fixture-generation command/log.

| Required check | Status | Evidence/notes |
| --- | --- | --- |
| Main-thread filesystem/index stress | `NOT RUN` | Trace, fixture log, and maximum stall: |

## Regression sweep and decision

| Required check | Status | Evidence/notes |
| --- | --- | --- |
| Open, edit, direct File Save, Save As, close, and reopen | `NOT RUN` | |
| Quit with named, unnamed, unlisted, special, and read-only modified buffers | `NOT RUN` | |
| Sidebar create/rename/trash failure surfaces a native error and refreshes | `NOT RUN` | |
| Sidebar expansion, selection, and scroll layout survive targeted and root refreshes | `NOT RUN` | |
| Quick Open, buffer strip, cmdline, popup menu, minimap, and status bar | `NOT RUN` | |
| Reduce Motion and light/dark appearance | `NOT RUN` | |

Overall release decision: `NOT RUN`

Blocking failures and issue links: `NOT RUN`

Release owner sign-off and timestamp: `NOT RUN`

The trusted GUI-runner workflow stages the exact tested artifact and reruns
package verification plus a clean-profile smoke test. Main runs upload an
untouched template. Tag runs instead require, validate, and upload the completed
candidate-specific JSON record. The release job cannot start unless that
machine-enforced acceptance gate succeeds.
