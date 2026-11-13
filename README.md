# LLM Usage

A small macOS menu bar app that shows how much of your weekly allowance you have
used on each AI coding tool signed in on your Mac.

It reads what those tools already keep on your machine and asks each vendor's own
usage endpoint. It has no account, no server and no telemetry, and it is one Swift
file you can read in a sitting.

| Provider | Needs | What you see |
|---|---|---|
| Claude | Claude Code signed in | Weekly limits, 5-hour window, share by surface |
| Codex | Codex CLI signed in with ChatGPT | Weekly limit, plan, credits, limit resets |
| Gemini | Gemini CLI signed in | Per-model quota |
| Grok Build | `grok` CLI signed in | Weekly limit, plan, pay-as-you-go |
| Grok Bot | Grok Bot desktop app | Included usage, on-demand spend against cap |
| Muse Code | `muse` CLI signed in | Weekly and 5-hour windows |

Tools you don't have are left out of the menu entirely. On first launch a Setup
Check window lists what was found, what wasn't, and how to set each one up; it is
also in the dropdown at any time.

## Install

Requires macOS 13 or later, on Apple Silicon or Intel.

**From a release:** download the zip from [Releases](https://github.com/d0s1nt/llm-usage/releases), move `LLM Usage.app` to Applications and open
it. Releases that are not notarized need a right-click, then Open, the first time.

**From source** (needs the Xcode command line tools, `xcode-select --install`):

    git clone https://github.com/d0s1nt/llm-usage.git && cd llm-usage
    ./build.sh

That compiles to `~/Applications/LLM Usage.app` and launches it.

On first run macOS asks whether LLM Usage may read the "Claude Code-credentials"
keychain item. That is how it reads your Claude allowance. Choose Always Allow, or
Deny if you don't want the Claude row.

## Using it

The menu bar shows a gauge plus the provider closest to its limit, as its logo and
percentage used. Orange from 75%, red from 90%. Click it for every provider, each
limit window, and when it resets. It refreshes every 5 minutes and when opened.

The dropdown has these controls:

- **Launch at Login** also relaunches the app if it ever crashes.
- **Compact Menu Bar** (on by default) shows one provider. Turn it off to show all.
- **Renew Expired Sign-ins** (off by default), see below.
- **Refresh Now**.
- **Setup Check** shows which tools were found on this Mac and why any are missing.

The headline number is always the weekly or included allowance. Short windows and
spend caps appear as rows but don't drive it.

## What it touches

By default the app is read-only. It reads:

- the `Claude Code-credentials` keychain item, then calls `api.anthropic.com/api/oauth/usage`
- `~/.codex/auth.json`, then calls `chatgpt.com/backend-api/wham/usage`
- `~/.gemini/oauth_creds.json`, then calls Google's Code Assist quota endpoints
- nothing for Grok Build: it runs `grok agent stdio` and asks the agent for billing
  over its JSON-RPC protocol, so the CLI handles its own sign-in
- Grok Bot's cached reading in `~/Library/Application Support/Grok Bot/sand-client-persistence/`
  (no network at all)
- the output of `muse usage --json`, and Muse's session journal when its quota is exhausted

Tokens are sent only to the vendor that issued them. Nothing is sent anywhere else.

It writes three things: its own preferences, `~/Library/Logs/LLMUsage.log` (where
the menu bar item is on screen, for troubleshooting, capped at about 256 KB), and
the launch agent file if you turn on Launch at Login.

### Renew Expired Sign-ins

Claude Code and Codex sign-ins expire, and each tool renews its own when you use
it. If a row says its sign-in has expired, run that tool once.

Turning on **Renew Expired Sign-ins** lets LLM Usage do the renewal itself, using
the tool's own sign-in service, and save the new tokens where the tool keeps them.
That keeps rows fresh when you haven't used a tool for a while. The cost: those
tokens are single-use, so if the tool renews at the same moment, you may have to
sign in to it again. It is off unless you choose it.

Gemini access tokens last an hour, so the app renews those in memory either way.
Google does not rotate the underlying token, so nothing is disturbed, and the
Gemini CLI's file is only updated when the switch is on.

## Troubleshooting

**The icon isn't in the menu bar.** On a MacBook, macOS hides any item that would
land under the notch. Check the last lines of `~/Library/Logs/LLMUsage.log`: each
refresh records the item's position and whether it is occluded. Hold ⌘ and drag the
icon to the right to give it a visible slot, which macOS then remembers. If the log
has stopped, the app isn't running; look for a report named `LLMUsage-*.ips` in
`~/Library/Logs/DiagnosticReports`.

**A row says "stale".** The last refresh failed, so the previous numbers are shown
with their age. After an HTTP 429 the app backs off that provider for 15 minutes.

**Gemini shows no data on a Workspace account.** Add `GOOGLE_CLOUD_PROJECT=<id>` to
`~/.gemini/.env`.

**Muse shows "currently unavailable".** Meta only reports usage after a prompt has
run in the current window. Send one message in Muse.

**A tool you have isn't detected.** Command-line tools are looked for on your login
shell's PATH and in the usual install folders (Homebrew, `~/.local/bin`, npm, nvm,
fnm, asdf, bun, volta, cargo). If yours lives somewhere else, add that folder to the
PATH in `~/.zprofile`.

**Check from a terminal:**

    "$HOME/Applications/LLM Usage.app/Contents/MacOS/LLMUsage" --print
    ... --print C X                # only these providers, by letter or name
    LLMUSAGE_DEBUG=1 ... --print   # also prints response key names and non-secret values
    ... --setup                    # the Setup Check report as text
    ... --login on|off|status

## Building a release

    ./release.sh

writes `dist/LLM-Usage-<version>.zip`, ad-hoc signed. To produce one that opens
without a warning on any Mac, sign and notarize with an Apple Developer ID:

    xcrun notarytool store-credentials llm-usage     # once
    SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=llm-usage ./release.sh

`BUNDLE_ID` and `SIGN_ID` can also live in a git-ignored `.local.env` file. The
version comes from `VERSION`.

## Notes for contributors

- Everything is in `LLMUsage.swift`. A provider is a struct with `name`, a one-letter
  `short`, and `fetch()` returning a `ProviderStatus`; add it to `allProviders` and
  drop `icons/<letter>.svg` next to the others.
- File and pipe I/O must use the throwing `FileHandle` APIs or POSIX `read`. The
  legacy ones raise Objective-C exceptions that Swift cannot catch.
- Launch at Login is a plain plist in `~/Library/LaunchAgents`, not `SMAppService`.
  For an ad-hoc signed app launchd pins an `SMAppService` agent to the binary's hash,
  so every rebuild puts it in an exit-78 spawn loop.
- The usage endpoints are the ones each vendor's own tool uses. They are not
  documented public APIs and can change without notice.

## Trademarks

The provider logos in `icons/` are trademarks of their owners (Anthropic, OpenAI,
Google, xAI, Anysphere, Meta), used only to identify each service. This project is
not affiliated with or endorsed by any of them.

## Licence

MIT. See `LICENSE`.
