# Lock In

A native SwiftUI macOS focus app based on **Focus 1.15** as the feature reference. Requires macOS 14+, Swift 6 / Xcode. No external packages, server, accounts, or analytics.

## Run

```sh
bash Scripts/build-app.sh
open "dist/Lock In.app"
```

To build and install (or update) the app in `/Applications`, run `./install-app` (a shortcut for `Scripts/install-app.sh`). A running copy is told to quit with `lockin://update`. This pauses an in-progress session with the reason “Updating Lock In”, and the session resumes automatically once the new version opens. A pause you started yourself stays paused. In Hardcore Mode the app refuses to quit, and the script stops without changing the installed app.

Use the packaged app, rather than `swift run`, for browser Automation permission and URL handling. The build script creates an ad-hoc signed app for local development; set `CODESIGN_IDENTITY` to a Developer ID identity to sign it with the Hardened Runtime instead. Open `Package.swift` in Xcode to develop.

```sh
swift test
```

## Releases

Releases are built by GitHub Actions and published as a Developer ID signed, notarized `.app` zip on the GitHub release.

- `.github/workflows/ci.yml` builds, tests and packages the app on every push and pull request.
- `.github/workflows/release.yml` uses [release-please](https://github.com/googleapis/release-please). It keeps a release PR open from [conventional commits](https://www.conventionalcommits.org) on `main` (`feat:`, `fix:` and so on). Merging that PR bumps the version in `Resources/Info.plist`, updates `CHANGELOG.md`, tags the release, then builds, signs, notarizes and attaches the app.
- The release workflow refuses to run until the Apple signing secrets are set. Run `./Scripts/setup-release.ts` once (needs Deno and the `gh` CLI). It checks your Developer ID `.p12` and App Store Connect API key with the same tools CI uses before storing them as repository secrets.

## Daily work sessions

Open Lock In, enter your TODOs (each can have an optional link, shown as Linear, GitHub or Notion when it points there, or as the site name otherwise), and enter the number of hours of actual work. Start begins a finite work session.

- Work earns break time continuously at **5 minutes per hour**: two worked hours earns ten minutes. This is a proportional rate, not a two-hour unlock threshold.
- Taking a break spends the earned balance. Returning early preserves unused time; reaching zero resumes work automatically. Breaks cannot accrue more credit.
- Pausing requires a nonblank written justification. Pauses neither spend nor earn break credit. Quitting during work or a break opens that same justification prompt.
- Breaks and pauses do not count toward the work target. The session finishes naturally only after the target work time is reached.
- Tasks can be added to a running session, and existing tasks renamed or relinked with the pencil button. This works during a break or pause too. They’re saved to the session journal immediately and appear in the review like planned tasks.
- **Start new day…** ends the current session early (for example, one left paused overnight). It asks for a reason, prefilled as “Starting a new day”, and saves it as `end_reason`. The session is recorded as `finished_naturally: false` and goes to the usual review, so you can roll tasks into a new plan. Not available in Hardcore Mode.
- Completion opens a day timeline, including all work, break and pause intervals overlapping that calendar day. Edit task titles/links, mark TODOs complete, and select **Next session** separately for each task. Saving the review creates a new draft containing only selected tasks, with source-task IDs retained for lineage.
- Earned credit is scoped to each session and does not roll forward. Task rollover is explicit, including for completed tasks.
- Sleep and unexpected app downtime become system-explained pauses. App checkpoints are written every ten seconds; abrupt termination may lose at most the work since the last successful checkpoint. No idle/keyboard monitoring is performed: time counts as work while the work phase is running.
- Schedules now prompt for planning instead of starting unplanned sessions. Continuous Pomodoro and open-ended sessions are superseded by this work-target flow.

## Journal files

`~/.lockin/session-<UUID>.yaml` contains each session’s target, TODOs, optional links (with the recognized service), completion and rollover flags, and chronological work/break/pause intervals (including pause explanations). Timestamps use ISO 8601 UTC. Open intervals have `ended_at: null`; total durations are checkpointed every ten seconds and on transitions/review edits.

`~/.lockin/state.json` is an internal recovery snapshot for active sessions, draft tasks and pending reviews. YAML files are human-readable exports owned by the app; edit TODOs through the app, since external YAML edits are not imported. Files are written atomically one at a time. If a multi-file write is interrupted, the snapshot remains the recovery source and YAML is regenerated on the next save. Read failures preserve the original files and prevent new sessions. Write failures are shown in the app.

Links are saved as URLs only. No Linear, GitHub or Notion account access or API integration is required.

## Other features

- Native SwiftUI window and persistent menu-bar companion. Compact scope icon by default; Settings offers visibility, optional countdown, and a Restore menu-bar icon action.
- Domain/subdomain and URL-path rules, with block-list or allow-list mode.
- Safari and Chromium all-tab redirection, with an original local focus page.
- Application hiding that preserves unsaved work.
- Hardcore preferences lock and password-gated preferences.
- History and charts; shell hooks on start, stop, break, resume, and pause.
- Launch at login and global Control–Option–Command–F shortcut (opens pause justification during a session).
- `lockin://start`, `lockin://stop`, `lockin://pause`, `lockin://break`, `lockin://resume`, `lockin://update`; start respects planning/review requirements, stop requires a pause reason. `update` (used by the install script) pauses with “Updating Lock In”, quits, and resumes on relaunch; it is refused in Hardcore Mode.

## Browser permission

Open a supported browser and click **Enable browser blocking**. Lock In explicitly asks macOS for Automation access; if access is already allowed no prompt appears. Permission is managed in **System Settings → Privacy & Security → Automation**. The app scans tabs across all browser windows and redirects matching URLs. It checks permission before scanning, reports exact failures, and does not treat a failed scan as protection. The status line reports failures; permission is never silently assumed.

## What is not yet equivalent to Focus 1

This is a working first implementation, **not full feature parity**. The reference is `/Applications/Focus.app`, version 1.15, inspected on 2026-10-30. The public website now describes Focus 2, so it is not the source of truth for this app’s scope.

| Area | Current behavior / remaining work |
| --- | --- |
| Website enforcement | Checks the foreground browser tab every 250 ms and sweeps all supported browser windows every two seconds. Browser activation triggers an immediate check. Checks are serialized and scan scripts are reused; actual latency also depends on browser responsiveness. Content may load before redirection. Downloads, Firefox and non-browser traffic are not blocked. |
| Application enforcement | Hides selected apps repeatedly; does not prevent execution or terminate processes. |
| Tamper resistance | Normal UI controls honor locked sessions; force-quit or editing local data bypasses them. A privileged, signed helper or system extension needs a separate implementation. |
| Session workflow | Work-target planning replaces the v1 Pomodoro/open-ended flow. Hardcore still allows earned breaks and justified pauses. |
| Schedules | Local-time planning reminders; sessions must be planned and started explicitly. |
| Rules | Domain, subdomain, path-prefix and exact query matching. No arbitrary wildcard/regex patterns or browser-specific rules. |
| Do Not Disturb | No automatic OS Focus toggle; can be integrated through user-supplied workflow scripts/Shortcuts. |
| Block page | One original message; no custom quote collection/editor. The blocked URL is passed as `?url=`. Refreshing the block page returns to that URL: it stays open on a break, and is blocked again during work. |
| Menu bar | Countdown and popup controls; no custom icon/click-behavior preferences yet. |
| Automation | `lockin://` URL actions and shell hooks; no AppleScript dictionary or full Focus-compatible command schema. |
| Import | Does not read or alter your existing Focus preferences, sessions, license, or helper. |

The global shortcut may be unavailable if another app already owns it. macOS must keep Lock In running for enforcement and scheduling. The packaged build has not been validated across all supported browsers.

## Architecture

- `LockInCore`: Codable state, URL-rule matcher, schedule occurrence logic and session phase data; independently tested.
- `Store`: main-actor session orchestration, atomic JSON persistence, schedule firing and workflow execution.
- `Blocker`: serialized browser Apple events, cancellation on stop/break, application hiding.
- SwiftUI views: shared state for the window and menu-bar panel. AppKit handles app selection; Carbon registers the global shortcut without keystroke monitoring.

Blocking preferences and legacy history are saved to `~/Library/Application Support/LockIn/state.json`; new session journals are saved in `~/.lockin`. Failed decoding preserves the original file and disables writes. Workflow scripts run as your current user and are blank by default. No system hosts/proxy/network settings are changed.

## Reference

- Local Focus 1.15 bundle metadata and interface resources (feature labels only; no vendor code/assets copied).
- [Focus 2 announcement](https://heyfocus.com/blog/focus-2-a-big-step-in-getting-things-done/) for distinguishing the later profile-based feature set.
- [Apple MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra).
