# Lock In

A native macOS app for planning focused work, blocking distractions, and keeping a record of your day. Set a work target, choose your tasks, and earn break time as you go. Bring in Linear issues and GitHub pull requests to see the dependencies behind your work.

Built with SwiftUI. Requires macOS 14 or later. Sessions and settings stay in local JSON files; no Lock In account, server, or analytics. Linear and GitHub connections are optional.

## Get started

Download the app from [GitHub Releases](https://github.com/johnstonmatt/lockin/releases), unzip it, and move **Lock In.app** into `/Applications`.

To build and install from source, use a Swift 6 toolchain (included with a compatible Xcode installation):

```sh
./install-app
open "/Applications/Lock In.app"
```

The installer also links `lockin` into `~/.local/bin`. Add that directory to your `PATH`, or set `LOCKIN_BIN_DIR` when installing to choose another location. For a downloaded app, use **Settings → Command line → Install CLI**.

For your first session:

1. Open **Work** and choose **Add work**. Enter a task name or paste a link.
2. In **Distractions**, choose websites and applications to block.
3. Open a supported browser and click **Enable browser blocking**. Allow macOS Automation access when prompted.
4. In **Focus**, set your target hours and start the session.

The menu-bar companion keeps the timer and session controls close by. **Control–Option–Command–F** opens the pause prompt during a session.

## Sessions and breaks

The target measures time spent working. Breaks and pauses do not count toward it, and Lock In does not monitor keyboard activity or idle time.

| Action | What happens |
| --- | --- |
| Work | Earn five minutes of break time per hour, continuously. Two hours of work earns ten minutes. |
| Take an earned break | Spend the balance. Return early to keep unused time; work resumes automatically when it runs out. |
| Pause | Give a written reason. The work timer and break balance both stop. |
| Reach the target | Continue into overtime, with blocking and break earnings still active. Choose **Finish session** when done. |
| End early | Choose **Start new day…** and give a reason, then review the session. |

Add, rename, or relink tasks during work, breaks, or pauses. When the session ends, review your day’s timeline, mark tasks complete, and choose **Next session** for anything you want to carry forward. Task rollover is explicit; break credit stays with the session. Complete the review before starting another session.

**Hardcore Mode** locks preferences and prevents quitting, updating, or ending early until the work target is reached. Earned breaks and justified pauses remain available. Preferences can also be protected with a password; that password does not unlock a Hardcore session.

Sleep pauses the session. On wake, work resumes or an unfinished break continues; a pause you started yourself stays paused. Lock In checkpoints the session every ten seconds. After an unexpected exit, time after the last successful checkpoint becomes a pause.

## Work, issues, and pull requests

**Work** shows the current session’s tasks, or the next session’s plan. Use local tasks on their own, attach ordinary links, or import a Linear issue or GitHub PR through **Add work**.

### Connect Linear and GitHub

Open **Connections** with the key button:

- **Linear:** add a personal API key with read access to the relevant teams. Lock In stores it in macOS Keychain.
- **GitHub:** install the GitHub CLI and sign in with `gh auth login`. Lock In uses its existing credentials to read GitHub.com pull requests.

Imports use read-only APIs. They do not change issues or PRs, check out branches, or store credentials in the work files.

Importing a Linear issue brings in its descendants, linked PRs, and sequencing dependencies. The root is selected for the session; its descendants remain part of the imported hierarchy. Prerequisites outside that tree appear as muted **Context** cards. Choose **Include in session** to add one to your work.

### Choose a view

**Graph View** shows nested issue groups and dependency arrows. Solid arrows represent explicit Linear blockers or GitHub stack order; dashed arrows represent inferred branch relationships. Containment does not imply sequencing. Drag empty space to pan, pinch or use +/− to zoom, and choose **Fit graph** to center the view.

**List View** nests sub-issues and PRs beneath their parent issues. Collapse groups to reduce detail, or use the PR-only filter for a flat list with parent-issue breadcrumbs.

Both views share selection, filters, group collapse state, and the details panel. Lock In remembers your view choice. Dependencies and containment are read-only: correct them in Linear or GitHub, then choose **Refresh**. Refreshing reloads source data without adding removed tasks back to the session. Failed refreshes preserve the saved graph; imports are bounded at 250 issues and 400 PRs.

### Read status separately from progress

PRs show **Draft**, **Pending**, **Failing**, **Passing**, or **Ready**, with terminal labels for merged and closed PRs. Required checks determine check status; optional checks do not. **Ready** also requires satisfied review requirements and GitHub’s confirmation that merge gates are clear. Open the PR on GitHub to inspect individual checks.

A merged PR satisfies its dependencies; a closed, unmerged PR does not. **Done for this session** records your progress locally without changing Linear or GitHub. Completed and canceled source work is not automatically selected into the session. Source statuses refresh on request.

## Blocking distractions

Website rules support domains, subdomains, path prefixes, and exact query matching. Choose a block list, or an allow list that blocks other HTTP/S pages. Application blocking repeatedly hides selected apps while preserving their running processes and unsaved work.

Browser blocking supports **Safari, Chrome, Brave, Edge, Vivaldi, and Arc**. It redirects matching tabs to a local focus page. Refresh that page to return to the original URL during a break; the URL is blocked again during work.

Manage browser permissions in **System Settings → Privacy & Security → Automation**. Lock In reports permission and scan failures in its protection status.

Keep these limits in mind:

- The foreground browser tab is checked every 250 ms; background tabs are swept every two seconds. Browser responsiveness affects latency, and content can load before redirection.
- Firefox, downloads, and non-browser traffic are not filtered. Lock In does not change hosts, proxy, or network settings.
- Apps are hidden, not prevented from launching or terminated.
- Lock In must stay running. Force-quitting it or editing local data bypasses enforcement, including Hardcore Mode.
- Rules do not support arbitrary wildcards, regular expressions, or browser-specific settings.

## Command line

Run `lockin help` for the full command reference. Quote any text containing spaces.

```sh
lockin                                  # Current session status
lockin open                             # Open the app window
lockin status --json                     # Status for scripts
lockin task add "Fix the build"
lockin start --hours 6
lockin pause "Lunch with Sam"
lockin resume
lockin break                            # Countdown; Ctrl-C returns to work early
lockin tasks                            # Task numbers for the commands below
lockin task 2 "Fix the flaky build"
lockin task done 2                      # Also: task undo 2, task rm 2
lockin event add "Deployed to staging"
lockin finish                           # End after reaching the target
lockin end "Starting a new day"          # End early with a reason
lockin history -n 14
```

Tasks accept `"title"`, `"link"`, or `"title - link"`. A link alone gets a title derived from its URL without a network request. CLI task links do not import a dependency tree; use **Add work** in the app for imports.

`status`, `tasks`, and `history` read `~/.lockin` directly and work while the app is closed. Session changes go through the app, which launches in the background if needed. The same session rules apply: starting requires at least one task and no pending review, breaks must be earned, and pauses and early ends need a reason. Reviews happen in the app.

Exit codes are `0` for success, `1` for a refusal or failure, and `2` for invalid usage.

### Record missed work

Backfill time worked before starting Lock In or while it was paused:

```sh
lockin backfill 9:00-10:30
lockin backfill 23:00-now
lockin backfill 2026-11-03T22:30-2026-11-04T01:15
lockin backfill --undo
```

An end time earlier than the start crosses midnight. Undated ranges resolve to their most recent occurrence entirely in the past; the reply confirms the dates and times used.

Within a session, backfill turns pauses into work and preserves existing work and breaks. It can extend a session’s start earlier. A range outside all sessions creates an already-reviewed session; one spanning multiple sessions is refused. Backfilled intervals appear lighter on the timeline, and work beyond the target counts as overtime. Undo removes the last backfill while preserving subsequent activity.

### Automate a session

Settings includes optional shell hooks for start, stop, overtime, break, resume, and pause. They run as your user through `/bin/zsh`, with `LOCKIN_EVENT`, `LOCKIN_PROFILE`, and `LOCKIN_MODE` available. Hooks are blank by default. There is no automatic macOS Focus toggle; a hook can invoke your own workflow or Shortcut.

The app also handles `lockin://start`, `lockin://stop`, `lockin://pause`, `lockin://break`, `lockin://resume`, `lockin://finish`, and `lockin://update`. These respect session requirements: stop opens the pause-reason prompt, and finish requires the target to be reached. Use the CLI to supply reasons, edit tasks, and receive command results.

## Updates

Choose **Lock In → Check for Updates…** or **Settings → Updates → Check for Updates…**, then **Install update** when a release is available. From the terminal:

```sh
lockin upgrade
```

The updater downloads the latest GitHub release and verifies its signature and notarization before installing it. Checking alone does not install anything. CLI upgrades do nothing if the installed version is already current or newer.

Installation pauses an active session with “Updating Lock In” and resumes it when the app reopens. A pause you started yourself stays paused. Hardcore Mode blocks installation until the target is reached. The app’s updater does not require a CLI link or `PATH` setup.

## Your data

Lock In saves JSON files in `~/.lockin`:

| File | Contents |
| --- | --- |
| `sessions/<local-start-time>.json` | One session’s target, tasks, links, work/break/pause/overtime intervals, reasons, and events. Powers History and day reviews. |
| `settings.json` | Profiles, the next session’s plan, pending review, and launch bookkeeping. |
| `work-graph.json` | Imported work, source relationships, and snapshots referenced by session tasks. |

Each file includes a `$schema` pointing to its definition in [`Schemas/`](Schemas). Timestamps inside files use UTC ISO 8601 with microseconds. Session filenames use local time to the minute, with a suffix for collisions; sessions are identified by their stored ID, so renaming a file is safe.

Writes are atomic. Session files are saved before settings, and the open session is checkpointed every ten seconds. Quit Lock In before hand-editing its files so a save does not overwrite your edits.

An unreadable session file, or one from a newer format, is skipped with a warning and never overwritten. If settings cannot be read, Lock In stops saving until they are fixed. Connection credentials stay in Keychain or under the GitHub CLI’s management, separate from these files.

## Development

There are no external Swift package dependencies. Open `Package.swift` in Xcode, or build and test from the terminal:

```sh
swift test
bash Scripts/build-app.sh
open "dist/Lock In.app"
```

Use the packaged app for browser Automation permissions and URL handling. Local builds are ad-hoc signed; set `CODESIGN_IDENTITY` to a Developer ID identity to sign with the Hardened Runtime. `./install-app` builds and moves the app into `/Applications`.

The code is split into three targets:

| Target | Responsibilities |
| --- | --- |
| `LockInCore` | Session models, journal storage and file formats, website rules, work imports, and PR readiness. |
| `LockIn` | SwiftUI window and menu bar, session orchestration, blocking, work views, connections, and updates. |
| `LockInCLI` | The `lockin` command, journal reads, and requests to the running app. Bundled as `Contents/Helpers/lockin`. |

`Store` coordinates sessions and persistence. `WorkGraphStore` coordinates work selection and graph storage. `WorkPresentation` supplies the graph, list, and details views; hierarchy, layout, and edge routing have separate implementations. `Blocker` serializes browser Apple events and hides applications. `RemoteControl` handles CLI requests through the same store methods used by the UI.

On-disk types live in `FileFormat`, separately from application models. Tests validate saved files against the JSON Schemas.

### Releases

[CI](.github/workflows/ci.yml) builds, tests, and packages the app on pushes to `main` and pull requests. The [release workflow](.github/workflows/release.yml) uses release-please to maintain a release PR from conventional commits. Merging that PR updates the version and [changelog](CHANGELOG.md), creates a tag, and builds a Developer ID signed, notarized app zip.

`fix:` commits bump the patch version; `feat:` commits bump the minor. Before 1.0, breaking changes also bump the minor. A `Release-As: 1.0.0` commit footer requests that specific version.

Maintainers configure Apple signing secrets with `./Scripts/setup-release.ts`, which requires Deno and the GitHub CLI. It validates the Developer ID certificate and App Store Connect API key before storing repository secrets.
