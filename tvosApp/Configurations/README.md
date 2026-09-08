# Signing configuration

## What lives here

`Signing.xcconfig` is **tracked** and is attached to every target and
configuration. It holds no developer-specific values — it sets
`CODE_SIGN_STYLE` and then optional-includes `Signing.local.xcconfig`:

```
#include? "Signing.local.xcconfig"
```

`Signing.local.xcconfig` is **untracked** and is where `DEVELOPMENT_TEAM` goes.
`#include?` is xcconfig's optional include, so when the file is absent Xcode
skips it and the project builds unsigned with no setup:

```sh
cp Configurations/Signing.local.example.xcconfig \
   Configurations/Signing.local.xcconfig
# then set DEVELOPMENT_TEAM to your own Team ID
```

The tracked file is referenced unconditionally on purpose. Making
`Project.swift` reference an xcconfig only when it exists looks tidier but
breaks: Tuist caches generation metadata, so adding or removing the file can
leave a stale reference and fail generation with
"Configuration file not found".

## What Tuist does and does not do

Tuist 4 has **no** signing feature. The `tuist signing encrypt/decrypt`
commands from Tuist 3 — which kept encrypted `.p12` and `.mobileprovision`
files in-repo and installed them at generation time — were removed in v4, on
the reasoning that "signing is already solved by community tooling like
Fastlane and Xcode itself."

So Tuist only *declares* signing as build settings: `DEVELOPMENT_TEAM`,
`CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `PROVISIONING_PROFILE_SPECIFIER`,
`CODE_SIGN_ENTITLEMENTS`. Certificates and profiles are installed by something
else, before generation.

**No certificate or profile material is stored in this repository.**

## How releases are signed today: they aren't

`scripts/build-ipa.sh` archives with `CODE_SIGNING_ALLOWED=NO`,
`CODE_SIGNING_REQUIRED=NO`, and empty entitlements, then zips the `.app` into
an unsigned IPA that users sideload. Distribution certificates play no part.
The entitlements the app declares — App Groups, iCloud key-value store,
`aps-environment` — are inert in an unsigned build; they take effect only when
a real provisioning profile grants them.

## If signed distribution is added later

Two viable paths. Neither puts secrets in this repo.

**fastlane match** — certificates and profiles live encrypted in a separate
private git repo. CI decrypts into a temporary keychain *before*
`tuist generate`, then `Signing.xcconfig` is written from environment
variables. Set `CODE_SIGN_STYLE = Manual` and a
`PROVISIONING_PROFILE_SPECIFIER` matching the profile match installs, both in
`Signing.local.xcconfig`.

**App Store Connect API key** — an issuer ID, key ID, and `.p8` held as CI
secrets; `xcodebuild -allowProvisioningUpdates` fetches what it needs. Fewer
moving parts, but it requires signing to happen on a machine allowed to talk
to App Store Connect.

Whichever path, the rule stays: Tuist declares, something else supplies.
