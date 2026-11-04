# Lock In

A native SwiftUI macOS focus app. Requires macOS 14+, Swift 6 / Xcode. No external packages, server, accounts, or analytics.

## Run

```sh
bash Scripts/build-app.sh
open "dist/Lock In.app"
```

To build and install (or update) the app in `/Applications`, run `./install-app` (a shortcut for `Scripts/install-app.sh`, which builds and then runs `Scripts/install.sh`). To install the latest release instead, run `lockin upgrade`. A running copy is told to quit with `lockin://update`. This pauses an in-progress session with the reason “Updating Lock In”, and the session resumes automatically once the new version opens. A pause you started yourself stays paused. In Hardcore Mode the app refuses to quit, and the script stops without changing the installed app.

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
- Breaks and pauses do not count toward the work target.
- **Overtime:** reaching the target doesn’t end the session. Work continues as overtime, shown in purple and recorded as separate `overtime` intervals. The timer counts it up (`+00:12:34`), blocking stays on, and it earns break time at the same rate. **Finish session** ends it and opens the review, recorded as `finished_naturally: true`. Hardcore Mode stops applying once the target is met.
- Tasks can be added to a running session, and existing tasks renamed or relinked with the pencil button. This works during a break or pause too. They’re saved to the session journal immediately and appear in the review like planned tasks.
- **Start new day…** ends the current session early (for example, one left paused overnight). It asks for a reason, prefilled as “Starting a new day”, and saves it as `end_reason`. The session is recorded as `finished_naturally: false` and goes to the usual review, so you can roll tasks into a new plan. Not available in Hardcore Mode. Once the target is reached, **Finish session** replaces it.
- Completion opens a day timeline, including all work, break and pause intervals overlapping that calendar day. Edit task titles/links, mark TODOs complete, and select **Next session** separately for each task. Saving the review creates a new draft containing only selected tasks, with source-task IDs retained for lineage.
- Earned credit is scoped to each session and does not roll forward. Task rollover is explicit, including for completed tasks.
- Sleep and unexpected app downtime become system-explained pauses. Waking the Mac picks up where sleep left off: work resumes, or a break continues if break time is left. A pause you made yourself, or anything you changed while the Mac slept, is left alone. App checkpoints are written every ten seconds; abrupt termination may lose at most the work since the last successful checkpoint. No idle/keyboard monitoring is performed: time counts as work while the work phase is running.
- Continuous Pomodoro and open-ended sessions are superseded by this work-target flow.

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
- `lockin://start`, `lockin://stop`, `lockin://pause`, `lockin://break`, `lockin://resume`, `lockin://finish`, `lockin://update`; `finish` ends a session that has reached its target; start respects planning/review requirements, stop requires a pause reason. `update` (used by the install script) pauses with “Updating Lock In”, quits, and resumes on relaunch; it is refused in Hardcore Mode.

## Command line

Installing the app, whether with `./install-app` or `lockin upgrade`, links a `lockin` command into `~/.local/bin`, or into `$LOCKIN_BIN_DIR` if you set it. The link points into the installed app, so updating the app updates the command too. If you installed the app another way, use **Settings → Command line → Install CLI** to make the same link.

Free text is always one argument, so quote anything with spaces: `lockin pause "lunch with Sam"`. Unquoted words are a usage error, and the message shows the quoted command to run instead.

```sh
lockin                                   # status: phase, time left, break balance, tasks
lockin open                              # open the Lock In window
lockin status --json                     # the same, for scripts and status lines
lockin task add "Fix the build - https://linear.app/…/FUNC-1"
lockin task add "https://github.com/supabase/edge-runtime/pull/412"   # titled "supabase/edge-runtime#412"
lockin start --hours 6                   # start from the plan, optionally setting the target
lockin pause "lunch with Sam"
lockin break                             # counts the break down; Ctrl-C gets back to work early
lockin resume
lockin tasks                             # numbered: use the numbers below
lockin task 2 "Fix the flaky build"      # new title; a link alone replaces just the link
lockin task done 2                       # also: task undo <n>, task rm <n>
lockin finish                            # once the target is reached
lockin end "Starting a new day"          # end early, with a reason
lockin history -n 14
lockin upgrade                           # install the latest GitHub release
lockin backfill 6:20-now                 # record time you worked without Lock In counting it
```

A task is written as `"title"`, `"link"` or `"title - link"`. A link is split from the title at the last ` - `, so titles can contain ` - ` too. A task given only a link is titled from the URL, without any network access. A Linear issue becomes `FUNC-1033 github workflows cannot exceed 3600s`, a GitHub PR or issue becomes `owner/repo#412`, and a Notion page becomes its page name. Anything else becomes the host and path.

`lockin break` takes an earned break, or joins the one already running, and keeps a countdown on screen until the break ends. Ctrl-C ends it early and keeps the unused break time. It also stops if the app pauses or ends the session.

`lockin backfill <range>` records work Lock In didn't count, such as time after it paused for sleep, or before you remembered to start. A range is `9:00-10:30`, `22:30-01:15`, `23:00-now`, or dated, as in `2026-11-03T22:30-2026-11-04T01:15`.
- An end earlier than the start runs past midnight.
- Times without a date mean their most recent occurrence that's entirely in the past, so `23:00-00:20` run at 00:40 means last night.
- The range is placed on the timeline, not on a day. Inside a session, pauses in the range become work, and work or breaks already there are left as they were.
- A range running into the start of a session moves the session's start earlier.
- A range outside every session becomes a new, already-reviewed session.
- A range that covers parts of two sessions is refused, with both boundaries named.

Backfilled intervals are saved with `backfilled: true` (journal `schema_version: 4`) and drawn lighter in the day timeline. Work after the point the target is now reached is relabelled as overtime. The reply shows the exact times used, with dates. `lockin backfill --undo` removes the last backfill and keeps anything recorded since.

`lockin upgrade` fetches the latest release from GitHub and checks that it is signed and notarized. It then installs it with the `install.sh` that ships inside that release, the same script `./install-app` uses. If you're already on that version or a newer one, it does nothing.

`status`, `tasks` and `history` read `~/.lockin/state.json` and don't need the app running. If a session is open but the app isn't running, `status` reports the figures as of the last checkpoint, since that time won't count.

Everything else is carried out by the app. If the app isn't running, the command starts it in the background first. The CLI never writes the journal itself. It sends a request as a distributed notification, and the app replies with the outcome. The same rules apply as in the window: pauses and early ends need a reason, breaks must be earned, Hardcore Mode refuses `end`, and starting needs at least one task and no pending review. Reviews are still done in the app. Exit status is 0 on success, 1 when the app refuses a command, and 2 for a usage error.

Unlike `lockin://` URLs, which any web page can open, these requests can only come from processes running as you. So only the CLI can pause with a reason or edit tasks.

## Browser permission

Open a supported browser and click **Enable browser blocking**. Lock In explicitly asks macOS for Automation access; if access is already allowed no prompt appears. Permission is managed in **System Settings → Privacy & Security → Automation**. The app scans tabs across all browser windows and redirects matching URLs. It checks permission before scanning, reports exact failures, and does not treat a failed scan as protection. The status line reports failures; permission is never silently assumed.

## Limitations

This is a working first implementation. Current behavior and known gaps:

| Area | Current behavior / remaining work |
| --- | --- |
| Website enforcement | Checks the foreground browser tab every 250 ms and sweeps all supported browser windows every two seconds. Browser activation triggers an immediate check. Checks are serialized and scan scripts are reused; actual latency also depends on browser responsiveness. Content may load before redirection. Downloads, Firefox and non-browser traffic are not blocked. |
| Application enforcement | Hides selected apps repeatedly; does not prevent execution or terminate processes. |
| Tamper resistance | Normal UI controls honor locked sessions; force-quit or editing local data bypasses them. A privileged, signed helper or system extension needs a separate implementation. |
| Session workflow | Work-target planning, with no Pomodoro or open-ended sessions. Hardcore still allows earned breaks and justified pauses. |
| Rules | Domain, subdomain, path-prefix and exact query matching. No arbitrary wildcard/regex patterns or browser-specific rules. |
| Do Not Disturb | No automatic macOS Focus toggle; can be integrated through user-supplied workflow scripts/Shortcuts. |
| Block page | One original message; no custom quote collection/editor. The blocked URL is passed as `?url=`. Refreshing the block page returns to that URL: it stays open on a break, and is blocked again during work. |
| Menu bar | Countdown and popup controls; no custom icon/click-behavior preferences yet. |
| Automation | `lockin` CLI, `lockin://` URL actions and shell hooks; no AppleScript dictionary. |

The global shortcut may be unavailable if another app already owns it. macOS must keep Lock In running for enforcement. The packaged build has not been validated across all supported browsers.

## Architecture

- `LockInCore`: Codable state, URL-rule matcher and session phase data; independently tested.
- `Store`: main-actor session orchestration, atomic JSON persistence and workflow execution.
- `Blocker`: serialized browser Apple events, cancellation on stop/break, application hiding.
- `RemoteControl`: answers `lockin` CLI requests by calling the same `Store` methods as the UI.
- `LockInCLI`: the `lockin` command. It reads the journal directly and sends everything else to the app. It ships in the app bundle as `Contents/Helpers/lockin`.
- SwiftUI views: shared state for the window and menu-bar panel. AppKit handles app selection; Carbon registers the global shortcut without keystroke monitoring.

Blocking preferences and legacy history are saved to `~/Library/Application Support/LockIn/state.json`; new session journals are saved in `~/.lockin`. Failed decoding preserves the original file and disables writes. Workflow scripts run as your current user and are blank by default. No system hosts/proxy/network settings are changed.

## Reference

- [Apple MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra).
