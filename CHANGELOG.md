# Changelog

## 1.0.0

The first stable release. As with 0.3.0, Claude Code, Muse Code and Grok Build each
reviewed the app independently; every bug below was confirmed in the code first.

- A full limit on one model (Claude's weekly Opus or Fable limit, one Gemini model)
  no longer marks the whole tool as full, since other models still work.
- A tool whose sign-in has expired, or that keeps failing, is never the menu bar's
  pick, and agents are told it isn't usable now.
- An on-demand cap that's used up while the included allowance still has room is
  drawn in grey, with a note that the tool stops once the allowance runs out.
- "setup needed" when a signed-in tool needs a step from you (Gemini on a Workspace
  account), as distinct from "no figures yet".
- Grok Bot's row says when the Grok Bot app last checked, and only once that's over
  15 minutes ago, so it no longer reads like a failed refresh.
- Offline, one line says so instead of an error on every row, and Leeway refreshes as
  soon as the network is back.
- Turning on Limit Alerts says where macOS put its permission request and confirms
  with a notification once alerts are allowed.
- VoiceOver can open the links on provider and setup rows, and hears the same state
  the screen shows (full, paying, stale, setup needed, reset) plus the pace.
- Times and dates follow the Mac's language and 12- or 24-hour clock settings.
- For agents: `schema_version`, `error_kind`, `needs_setup`, `per_model` and
  `assumed_reset`, and ages that are worked out when asked rather than when saved.
- Fixed: a tool rate-limited before it ever showed figures was never asked again
  until Leeway restarted.
- Fixed: an unexpected empty reply from Codex, Grok or Muse wiped the last good
  figures (0.3.0 fixed this for Claude and Gemini only).
- Fixed: Muse could show an old "quota exhausted" reset time.
- Fixed: `~/.gemini/.env` lines with `export`, spaces around `=` or a trailing
  comment were ignored, and a Gemini CLI installed after Leeway started was never used
  to renew Gemini's sign-in.
- Fixed: Grok's agent refusing to start was reported as an expired sign-in.
- Fixed: errors and "reset" states were forgotten across a restart.
- Fixed: Check for Updates could offer a test build as the latest release.
- Privacy: the Setup Check report and `--print` no longer include the account email;
  debug output no longer shows account ids and goes to standard error; vendor error
  text has anything like an email or token removed; renewed Codex and Gemini
  credential files are never readable by other users, even briefly; a renewed Claude
  sign-in is passed to the keychain without appearing in the process list.

## 0.3.0

Ideas and bug reports for this release came from asking Claude Code, Muse Code and
Grok Build to review the app independently; the changes below are the ones they
agreed on.

- Knows when a tool can't take work, not just its weekly figure. A full 5-hour window
  or allowance shows "full · back in 2h" in red, and the menu bar never suggests that
  tool. If every tool is full, the menu bar says when the first one is back.
- On-demand spending is shown in dollars. When the included allowance is used up but
  on-demand money remains, the header says "paying · $32 of $80".
- A pace marker on each bar shows how much of the window's time has gone. Hover a
  row to see whether, at this rate, it runs out before it resets.
- Limit Alerts (Settings, off by default): local notifications when a tool passes
  90%, fills up, comes back, or starts spending on-demand money.
- Agents get more to decide with: `usable_now`, `blocked_until`, `paid_only`,
  on-demand dollars, pace and projected run-out, and the age of the figures.
  `best_available` puts tools that can take work now first. A live fetch from
  `--mcp` or `--json` is saved for the next agent, and a keychain prompt nobody
  answers can't hang an agent for more than 15 seconds.
- Honest about old figures: an expired sign-in keeps its warning and the menu bar
  "!" even while older figures are shown; figures restored after a restart are
  marked stale; figures whose reset time has passed show as reset; refreshes after
  the Mac wakes.
- Full menu bar mode says "used" or "left", like compact mode.
- Setup instructions are no longer cut off.
- Fixed: a Codex 5-hour window could become Codex's headline figure.
- Fixed: renewing a Codex or Gemini sign-in could leave its credential file
  readable by other users on the Mac.
- Fixed: the Gemini sign-in renewal didn't encode its form, and the search for the
  Gemini CLI's client details could wander outside the CLI's own folder.
- Fixed: a denied or cancelled keychain prompt made Claude look not set up, and an
  unexpected empty reply from Claude or Gemini wiped the last good figures.
- Fixed: with Show Remaining on, a tool at 100% drew as an empty grey bar.
- Fixed: a rate limit on the very first fetch didn't trigger the 15-minute backoff.
- Fixed: `--mcp` and `--json` could crash if the reader closed the pipe early.
- Fixed: Muse's figures could depend on the order of fields in its reply.

## 0.2.1

- The menu bar now agrees with the dropdown: its bars fill by what's used, and its
  figure says "used", unless Show Remaining is on, in which case both count down
  what's left. Before, the menu bar always showed what was left while the dropdown
  showed what was used, so the two looked contradictory.
- The "used" or "left" label in the menu bar is easier to read.

## 0.2.0

First release intended for anyone to install, under a new name: **Leeway** (previously LLM Usage).

- AI agents can query usage: a built-in MCP server (`--mcp`) with `get_usage` and
  `best_available`, a Connect AI Tools menu item, `--json` output, and a snapshot
  file. Agents never see the account email or tokens. Verified with Grok's own MCP
  diagnostics.
- Disk image with drag-to-Applications, alongside the zip. Releases are built by
  GitHub Actions from the tagged commit, with a signed build provenance attestation
  and checksums.
- Runs on Intel as well as Apple Silicon, tested on both in CI.
- Redesigned dropdown: fixed columns so figures never collide, coloured percentages
  near a limit, shorter notes, account shown on hover, tools awaiting setup listed
  last, and settings gathered into a Settings submenu.
- New menu bar item: a bar per tool showing what's left, then the tool with the most
  leeway. It used to show only the most-used tool, which was useless once that tool
  was exhausted.
- Restarts begin from the last saved figures instead of an empty menu.
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
