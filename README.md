# Repro: prebuilt Expo module xcframeworks ABI-incompatible with resolved expo-modules-core

Minimal reproduction for an ABI skew in Expo SDK 56's precompiled iOS modules:
`expo-file-system@56.0.8` and `expo-font@56.0.6` ship prebuilt xcframeworks compiled
against `expo-modules-core@56.0.16`, which added/renamed `Record` and `AnyModule`
protocol requirements. When a project resolves `expo-modules-core@56.0.15` (or older)
alongside them, the embedded `ExpoModulesCore.framework` is missing 10 symbols that
`ExpoFileSystem.framework` / `ExpoFont.framework` **strongly** bind to. Result:

- App Store Connect emits **ITMS-90863** ("uses symbols that aren't present in macOS:
  `@rpath/ExpoModulesCore.framework/ExpoModulesCore` …") listing exactly those symbols, and
- dyld aborts at app launch (`Symbol not found`), since the references are strong binds
  (verified with `dyld_info -fixups`: plain `bind`, no weak-import flag).

No package-manager warning or build error surfaces this: the prebuilt packages declare only
`"expo": "*"` peers, so the broken combination installs and builds cleanly.

## How this happens in the real world

This repo pins `expo-modules-core@56.0.15` via `overrides` purely to make the repro
deterministic. The same state arises **without any override**: a lockfile created before
2026-06-10 resolved `expo@56.0.9` → `expo-modules-core@~56.0.15` → `56.0.15`. A later
dependency-bot or targeted update of `expo-file-system`/`expo-font` (published 2026-06-10,
~40 min after core 56.0.16) floats them to the new wave while the package manager keeps the
still-range-satisfying `expo-modules-core@56.0.15` lockfile entry. That is exactly how our
production app shipped a broken TestFlight build.

## Reproduce (fast — no Xcode build needed, ~10s)

The prebuilt binaries ship inside the npm tarballs, so the incompatibility can be shown
directly with `nm`:

```bash
npm install
npm run check-abi
```

Expected (correct) outcome: every `ExpoModulesCore` import of every prebuilt module binary
is exported by the resolved `expo-modules-core` prebuilt binary.

Actual outcome: 10 unresolved imports per module binary, e.g.

```
❌ expo-file-system@56.0.8 (ExpoFileSystem): 10 of 184 ExpoModulesCore imports are NOT exported by expo-modules-core@56.0.15:
     _$s15ExpoModulesCore6RecordP4from10dictionary10appContextxSDySSypG_AA03AppH0CtKFZTq
     ...
     _$s15ExpoModulesCore9AnyModulePAAE22_synthesizedDefinitionSayAA0dG0_pGyF
```

Demangled, these are the requirements/default implementations added in core 56.0.16:
`Record.from(dictionary:appContext:)`, `Record.from(object:appContext:)`,
`Record.toObject(appContext:)`, `AnyModule._synthesizedDefinition()`,
`AnyModule._decorateModule(object:in:appContext:)` (PRs #46547, #46612).

The reverse direction breaks too: 56.0.16 removed the `_exposedDefinition` symbols that
module binaries built against 56.0.9–56.0.15 import.

## Reproduce (full build)

1. `npx expo prebuild -p ios && cd ios && pod install` (precompiled modules are the SDK 56
   default; `ExpoFileSystem`/`ExpoFont`/`ExpoModulesCore` link as prebuilt xcframeworks).
2. Build and run on an iOS device/simulator → dyld abort at launch, or
3. Archive, upload to App Store Connect → ITMS-90863 email listing the symbols above
   (once per referencing framework).

## Suggested fixes

- Couple prebuilt packages to the exact `expo-modules-core` version (or ABI tag) they were
  compiled against, so resolution can't mix waves; and/or
- Validate at `pod install` time (expo-modules-autolinking already has a
  fall-back-to-source path) that each prebuilt artifact's `ExpoModulesCore` imports are
  satisfied by the resolved core artifact, falling back to a source build on mismatch.
