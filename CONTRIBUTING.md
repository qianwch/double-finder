# Contributing to Double Finder

Thanks for taking a look. Issues and pull requests are both welcome.

## Before you start

For anything larger than a bug fix, please open an issue first and describe the
behavior you want. Double Finder deliberately follows Total Commander's
workflow, so "how would TC do this?" is usually the deciding argument — it is
cheaper to agree on that before the code exists.

Security problems go to [`SECURITY.md`](SECURITY.md), **not** to a public
issue.

## Building

```bash
brew install libmtp   # required — the Android/MTP backend links it,
                      # and the whole package fails to compile without it
swift build
"$(swift build --show-bin-path)/Double Finder"
```

Other useful commands:

```bash
swift test          # pure-logic unit tests
./package_app.sh    # → ./.dist/Double Finder.app
./package_dmg.sh    # → ./.dist/Double Finder.dmg
```

macOS 13 or later, Apple Silicon or Intel. Xcode's SourceKit index sometimes
lags and reports "cannot find type X in scope" — `swift build` is the
authority.

## Ground rules for a change

1. **Keep it focused.** One behavior change per pull request; unrelated
   cleanups belong in their own.
2. **Match the surrounding code.** Pure AppKit, no SwiftUI. State is reactive
   through `PanelState.onChange` callbacks, not Combine — if you change state,
   make sure the callback fires or call `updateDisplay()` yourself.
3. **Build clean.** `swift build` and `swift test` must pass, and new code
   should not add warnings.
4. **User-visible strings go through `tr()`.** The translation key *is* the
   full English source string (identity fallback), so an untranslated string
   still renders in English. Add the new key to every JSON bundle under
   `Sources/double-finder/Resources/Localization/` that you can; English-only
   is acceptable for a first pass.
5. **Sheets and window controllers need a strong reference to stay alive**
   (the `activeXxxSheet` pattern), cleared only in the `beginSheet` completion
   handler.
6. **Say what a user would see.** The pull-request description should state
   the user-visible behavior change, and how you verified it — there is no
   automated test coverage for the AppKit layer, so "built and clicked
   through it" (ideally with a screenshot) is the expected evidence.

## Commit messages

Plain English, imperative mood, in the style of the existing history:
`feat(connect): connect a saved S3 with its stored secret`. Describe what the
change does for the user rather than which files moved.

## License

By contributing you agree that your contribution is licensed under the
Apache License 2.0, the same as the rest of the project.
