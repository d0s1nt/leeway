# Changelog

## 0.2.0

First release intended for anyone to install.

- Disk image with drag-to-Applications, alongside the zip. Releases are built by
  GitHub Actions from the tagged commit, with a signed build provenance attestation
  and checksums.
- Runs on Intel as well as Apple Silicon, tested on both in CI.
- App icon, an About window, and a manual Check for Updates.
- VoiceOver reads every row of the dropdown.
- Finds command-line tools through your login shell's PATH (zsh, bash or fish) and
  the usual install folders, without hanging if a shell profile is slow.
- Launch at Login refuses to point at a temporary or disk-image copy of the app, and
  follows the app if you move it.
- A self-test covers every provider's response parsing with synthetic data.
- The placement log is written only when something changes.
- Fixed: `--login` crashed when run from a terminal.

## 0.1.1

- Show Remaining switch: numbers and bars count down what's left.
- Codex shows ChatGPT's own plan names.
- Secret scan for files, history and release builds.

## 0.1.0

- First public preview.
