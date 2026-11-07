# Maintainer announcements

Edit [`announcements.json`](announcements.json) on the repository's `main` branch to publish a message to users whose app build includes announcement support. Older app builds will need an update before they can read this feed. After that first update, publishing messages does not require another app release.

The checked-in feed starts empty. The example below is documentation only; it is not an active announcement.

```json
{
  "schemaVersion": 1,
  "announcements": [
    {
      "id": "2026-10-24-maintenance",
      "title": "Upcoming maintenance",
      "message": "Account sync may be briefly unavailable during maintenance. You can continue using your installed add-ons.",
      "linkURL": "https://github.com/Arrgh106/NuvioTVOSxIPTV/discussions"
    }
  ]
}
```

## Publishing

1. Edit the root `announcements.json` file in GitHub or your checkout.
2. Give each new announcement a new, unique `id`. Put messages in the order you want them shown.
3. Review the title, message, optional link, and time window, then commit or merge the change into `main`.

The app reads:

`https://raw.githubusercontent.com/Arrgh106/NuvioTVOSxIPTV/main/announcements.json`

Apps check when opened or resumed, at most once per hour. Publishing is not an immediate push to closed apps. Each device receives the message on its next eligible successful check. A failed check also counts toward the hourly limit.

To stop showing announcements, publish an empty `announcements` array. Devices clear their cached feed after the next successful check. Use `endsAt` when a cached message must stop being eligible even if a device cannot fetch the latest file.

## Message fields

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | Yes | Unique ID, 1–80 ASCII letters, digits, periods, underscores, or hyphens. |
| `title` | Yes | Plain-text heading, 1–80 characters after trimming whitespace. |
| `message` | Yes | Plain-text message, 1–240 characters after trimming whitespace. |
| `linkURL` | No | HTTPS link without an embedded username or password. When present, the details sheet shows its QR code and URL. |
| `startsAt` | No | ISO 8601 timestamp. The message becomes eligible at this time. |
| `endsAt` | No | ISO 8601 timestamp. The message stops being eligible at this time. Must be later than `startsAt` when both are set. |

For a time window, use UTC timestamps ending in `Z`, for example `"startsAt": "2026-10-24T18:00:00Z"` and `"endsAt": "2026-10-25T06:00:00Z"`. Choose dates for your own announcement. Omit both fields to make the message eligible immediately. A message without a link still has a readable details sheet.

The feed supports up to 10 announcements and a maximum response size of 64 KiB. IDs must not be duplicated. The entire incoming feed is ignored if its JSON, schema version, or any announcement is invalid; the app retains previously valid cached announcements that are still eligible.

## What users see

- One floating notice at a time on Home, with focus on its primary action. Notices stay out of login, profile selection, and playback.
- A newer app release takes priority. After dismissing or skipping that release, the next eligible announcement can appear.
- **Read Message** opens the native details sheet, including a QR code when the announcement has a link.
- **Dismiss** hides that announcement until the app is reopened.
- **Don't Show Again** remembers that announcement ID on the device, across profiles and app launches.
- **Settings → About → Announcements** has its own toggle. It is independent of app update checks.

Skipped IDs stay skipped even if you edit their text. Use a new ID for a new message that should be shown again. Multiple messages are considered in feed order, skipping those that are expired, not yet active, dismissed for the session, or permanently skipped.
