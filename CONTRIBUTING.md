# Contributing to Lock In

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

`Store` coordinates sessions and persistence. `WorkInput` parses and validates work for both the UI and CLI. `WorkGraphStore` coordinates selection and storage; `WorkImportStore` owns import execution, cancellation, and results. CLI commands await the `WorkOperation` returned by add/import commands; the UI can dismiss once an import starts. `WorkPresentation` supplies the graph, list, and details views; hierarchy, layout, and edge routing have separate implementations. `Blocker` serializes browser Apple events and hides applications. `RemoteControl` handles CLI requests through the same store methods used by the UI.

On-disk types live in `FileFormat`, separately from application models. Tests validate saved files against the JSON Schemas.

## Releases

[CI](.github/workflows/ci.yml) builds, tests, and packages the app on pushes to `main` and pull requests. The [release workflow](.github/workflows/release.yml) uses release-please to maintain a release PR from conventional commits. Merging that PR updates the version and [changelog](CHANGELOG.md), creates a tag and a draft GitHub release, and builds a Developer ID signed, notarized app zip. The release is published once that zip is attached, so the in-app updater and CLI never see a release without its download.

`fix:` commits bump the patch version, `feat:` commits bump the minor, and breaking changes (`feat!:` or a `BREAKING CHANGE:` footer) bump the major. A `Release-As: x.y.z` commit footer requests that specific version.

Maintainers configure Apple signing secrets with `./Scripts/setup-release.ts`, which requires Deno and the GitHub CLI. It validates the Developer ID certificate and App Store Connect API key before storing repository secrets.
