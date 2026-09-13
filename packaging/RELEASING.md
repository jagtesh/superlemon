# Publishing a release

There are two distribution paths. Always describe which was used in the release
notes; an ad-hoc signature does not establish a Developer ID identity or Apple
notarization, and automated smoke tests do not imply manual acceptance.

## Manual ad-hoc binary

1. Run `swift test`, `bash runtime/tests/run.sh`, and both Python validation
   suites in `scripts/tests/`. Commit and push the reviewed changes to main.
2. Run `scripts/release.sh` to bump the patch version and atomically push the
   release commit and tag. This starts CI but does not itself upload a binary.
3. On the clean tagged checkout, run `SUPERLEMON_SIGNING_MODE=adhoc
   scripts/package-app.sh release` (on one shell line). Check that the bundle's
   `SuperlemonVersion` exactly matches the tag without a dev/dirty suffix.
4. Run the bundled executable with `--smoke` using disposable HOME/XDG
   directories, then open the app and inspect the editor visibly. Record the
   actual tests and any unperformed checks in the release notes.
5. Archive with `ditto -c -k --sequesterRsrc --keepParent
   dist/Superlemon.app dist/Superlemon-X.Y.Z-macOS-arm64.zip` and generate its
   SHA-256 from inside `dist` so the digest file uses a portable filename.
6. Create the GitHub Release with `gh release create`, `--verify-tag`, the ZIP,
   digest file and a notes file. Explicitly label it ad-hoc signed and not
   notarized. Verify the uploaded asset digest and size.
7. Refresh the screenshot from the built application and publish the matching
   Homebrew formula with `scripts/publish-homebrew-formula.sh X.Y.Z`.

The binary requires macOS 14+ and Apple Silicon. Homebrew builds locally and
also has a pinned Intel Neovim dependency. Do not claim Intel validation unless
it was actually performed.

## Protected notarized pipeline

The tag workflow in `.github/workflows/build.yml` requires successful hosted
headless checks and Developer ID/notarization credentials in the protected
`release` environment. GUI acceptance is reviewed manually before approval;
CI does not require an interactive runner or enforce the acceptance record.
Follow [RELEASE_ACCEPTANCE.md](RELEASE_ACCEPTANCE.md). Do not mark unperformed
checks PASS or describe a manual ad-hoc archive as having passed this gate.
