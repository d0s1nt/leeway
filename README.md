# LLM Usage

[![CI](https://github.com/d0s1nt/llm-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/d0s1nt/llm-usage/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/d0s1nt/llm-usage)](https://github.com/d0s1nt/llm-usage/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
[![MIT licence](https://img.shields.io/badge/licence-MIT-green)](LICENSE)

A macOS menu bar app that shows how much of your weekly allowance you have used on
each AI coding tool signed in on your Mac.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/preview-dark.png">
  <img src="docs/preview-light.png" width="380" alt="The LLM Usage dropdown, showing weekly usage bars for Claude, Codex, Grok, Grok Bot and Muse">
</picture>

<sub>Illustrative figures.</sub>

It reads what those tools already keep on your Mac and asks each vendor's own usage
endpoint. No account, no server, no telemetry, and read-only by default. It's one
Swift file you can read in a sitting.

| Provider | Needs | What you see |
|---|---|---|
| Claude | Claude Code signed in | Weekly limits, 5-hour window, share by surface |
| Codex | Codex CLI signed in with ChatGPT | Weekly limit, plan, credits, limit resets |
| Gemini | Gemini CLI signed in | Per-model quota |
| Grok Build | `grok` CLI signed in | Weekly limit, plan, pay-as-you-go |
| Grok Bot | Grok Bot desktop app | Included usage, on-demand spend against cap |
| Muse Code | `muse` CLI signed in | Weekly and 5-hour windows |

Tools you don't have are left out. On first launch a Setup Check window lists what
was found and how to set up the rest.

## Install

Needs macOS 13 or later, on Apple Silicon or Intel.

1. Download the `.dmg` from the [latest release](https://github.com/d0s1nt/llm-usage/releases/latest).
2. Open it and drag **LLM Usage** to **Applications**.
3. In Applications, **right-click LLM Usage and choose Open**, then Open again.
   This is needed once, because releases aren't yet notarized by Apple.
4. Optional: in the dropdown, turn on **Launch at Login**.

If macOS says the app "can't be opened", go to System Settings, Privacy & Security,
and click **Open Anyway** next to LLM Usage.

<details>
<summary>Verify a download</summary>

Releases are built by GitHub Actions from the tagged commit, with a signed build
provenance attestation. With the GitHub CLI:

    gh attestation verify LLM-Usage-0.2.0.dmg --repo d0s1nt/llm-usage

`SHA256SUMS.txt` on each release lists the checksums.
</details>

<details>
<summary>Build from source</summary>

Needs the Xcode command line tools (`xcode-select --install`).

    git clone https://github.com/d0s1nt/llm-usage.git && cd llm-usage
    ./build.sh

That compiles a universal app to `~/Applications/LLM Usage.app` and launches it.
</details>

## Using it

The menu bar shows a gauge plus the provider closest to its limit, as its logo and
percentage. Orange from 75%, red from 90%. Click it for every provider, each limit
window and when it resets. Click a provider's name to open its usage page. Figures
refresh every 5 minutes and whenever you open the menu.

The headline number is always the weekly or included allowance. Short windows and
spend caps appear as rows but don't drive it.

| Menu item | What it does |
|---|---|
| Refresh Now | Fetches every provider again |
| Setup Check… | Which tools were found on this Mac, and how to fix the rest |
| Launch at Login | Starts at login, and relaunches the app if it ever crashes |
| Compact Menu Bar | On by default: one provider in the menu bar. Off: all of them |
| Show Remaining | Counts down what's left, like the vendors' own screens |
| Renew Expired Sign-ins | Off by default. See below |
| About / Check for Updates… | Version, licence, and a manual check for a newer release |

## Privacy and what it touches

By default the app only reads. Specifically:

- **Claude:** the `Claude Code-credentials` keychain item, then `api.anthropic.com/api/oauth/usage`.
  macOS may ask whether to allow this; Allow, or Deny if you don't want the Claude row.
- **Codex:** `~/.codex/auth.json`, then `chatgpt.com/backend-api/wham/usage`.
- **Gemini:** `~/.gemini/oauth_creds.json`, then Google's Code Assist quota endpoints.
- **Grok Build:** nothing directly. It runs `grok agent stdio` and asks the agent for
  billing, so the CLI handles its own sign-in.
- **Grok Bot:** the reading the app already cached in `~/Library/Application Support/Grok Bot/`.
  No network at all.
- **Muse:** the output of `muse usage --json`, and Muse's session journal when its
  quota is exhausted.

Each token goes only to the vendor that issued it. The only other network request
is **Check for Updates…**, which asks GitHub's public API for the release list, and
only when you choose it.

It writes its own preferences, a small log at `~/Library/Logs/LLMUsage.log` (where
the menu bar item is placed, only when that changes), and a launch agent in
`~/Library/LaunchAgents` if you turn on Launch at Login.

### Renew Expired Sign-ins

Claude Code and Codex sign-ins expire, and each tool renews its own when you use it.
If a row says its sign-in has expired, run that tool once.

Turning on **Renew Expired Sign-ins** lets LLM Usage do the renewal itself, using the
tool's own sign-in service, and save the new tokens where the tool keeps them. That
keeps rows fresh for tools you haven't used in a while. The cost: those tokens are
single-use, so if the tool renews at the same moment, you may have to sign in to it
again. It's off unless you choose it.

Gemini access tokens last an hour, so those are renewed in memory either way, using
the client details from your own Gemini CLI install. Google doesn't rotate the
underlying token, and the Gemini CLI's file is only updated when the switch is on.

## Troubleshooting

**The icon isn't in the menu bar.** On a MacBook, macOS hides menu bar items that
would sit under the notch. Hold ⌘ and drag the icon to the right; macOS remembers
the spot. The log at `~/Library/Logs/LLMUsage.log` records the item's position and
whether it's hidden. If the app isn't running at all, look for `LLMUsage-*.ips` in
`~/Library/Logs/DiagnosticReports`.

**A tool you have isn't detected.** Command-line tools are looked for on your login
shell's PATH (zsh, bash or fish) and in the usual install folders: Homebrew,
`~/.local/bin`, npm, nvm, fnm, asdf, bun, volta and cargo. If yours lives elsewhere,
add that folder to your PATH in your shell profile.

**A row says "stale".** The last refresh failed, so the previous figures are shown
with their age. After an HTTP 429 that provider is left alone for 15 minutes.

**Launch at Login won't turn on.** Move the app to Applications and open it from
there. macOS runs apps opened straight from Downloads or a disk image from a
temporary location that a login item can't point to.

**Gemini shows no data on a Workspace account.** Add `GOOGLE_CLOUD_PROJECT=<id>` to
`~/.gemini/.env`.

**Muse shows "currently unavailable".** Meta only reports usage after a prompt has
run in the current window. Send one message in Muse.

**From a terminal**, using the app's own binary:

    BIN="/Applications/LLM Usage.app/Contents/MacOS/LLMUsage"
    "$BIN" --setup          # the Setup Check report as text
    "$BIN" --print          # every provider's figures
    "$BIN" --print C X      # only some providers, by letter or name
    "$BIN" --selftest       # parser tests against built-in synthetic data
    "$BIN" --login status   # or on, off

When reporting a problem, include the `--setup` output, but remove your email
address from it first.

## Uninstall

1. In the dropdown, turn off **Launch at Login**, then Quit.
2. Delete `LLM Usage.app` from Applications.
3. Optionally remove its settings and log:

       defaults delete app.llmusage.menubar
       rm -f ~/Library/Logs/LLMUsage.log ~/Library/LaunchAgents/app.llmusage.menubar.plist

It never changed anything belonging to the AI tools, unless you turned on Renew
Expired Sign-ins.

## Contributing

- Everything is in `LLMUsage.swift`. A provider is a struct with a `name`, a
  one-letter `short` and a `fetch()` returning a `ProviderStatus`. Keep the response
  parsing in a pure `static func parse` so `--selftest` can cover it with synthetic
  data, add it to `allProviders`, and add `icons/<letter>.svg`.
- `./build.sh` builds and launches. `./release.sh` builds the DMG and zip, runs the
  self-test and the secret scan. CI does both on Apple Silicon and Intel.
- Run `./check-secrets.sh --install` once. It blocks a push that contains token
  shapes, home paths, email addresses or account ids, in any file or any commit.
  Never paste real tokens, `auth.json` contents or `--print` output into code,
  tests, issues or commits.
- File and pipe I/O must use the throwing `FileHandle` APIs or POSIX `read`. The
  legacy ones raise Objective-C exceptions that Swift can't catch.
- Launch at Login is a plain plist in `~/Library/LaunchAgents`, not `SMAppService`,
  because launchd pins an ad-hoc signed `SMAppService` agent to one exact build.
- The usage endpoints are the ones each vendor's own tool uses. They aren't public
  APIs and can change without notice.

Releases: bump `VERSION`, add a `CHANGELOG.md` section, tag `v<version>` and push the
tag. The release workflow builds, attests and publishes. For notarized builds, see
the header of `release.sh`.

Security issues: see [SECURITY.md](SECURITY.md).

## Trademarks

Provider logos in `icons/` are trademarks of their owners (Anthropic, OpenAI,
Google, xAI, Anysphere, Meta), used only to identify each service. This project
isn't affiliated with or endorsed by any of them.

## Licence

MIT. See [LICENSE](LICENSE).
