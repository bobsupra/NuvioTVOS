# First PR batch: visual validation

Baseline: 35704ed75. Integration: 6fdfe67df95531bc994664a0ffc40804b62ffd81.

Xcode 27.0; Apple TV 4K (3rd generation), tvOS 27.0 simulator. The integration passed 246 tests across StreamsDiscoveryTests, PlaybackBackendPolicyTests, PlayerControlsSettingsTests, HomeLayoutSettingsTests, and PosterCardStyleSyncTests.

## PR 243

Before: Match Subtitle Language is grayed out with Auto Select Stream off. After: the control receives remote focus and can be switched off/on with Auto Select Stream still off.

![Before](243-before.png)
![After](243-after.png)

## PR 251

Before/after Home Layout previews use the shared card modifier with AMOLED Mode and Pure Black Surfaces enabled. The preview remains legible with focused and unfocused cards. Artwork/gradient fills mask much of the underlying surface in this preview; these images do not establish physical-TV power savings or validate every shared-surface call site.

![Before](251-before.png)
![After](251-after.png)

These are simulator screenshots; physical-device playback, memory pressure, and delayed Jellyfin authentication flows were not exercised. UI test sources from PR 240 were syntax-checked but remain unregistered; PR 241 is held for tvOS-unavailable interactions.
