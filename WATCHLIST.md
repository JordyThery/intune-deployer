# Intune Deployer: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Settings Catalog on Graph beta (Microsoft):** `configurationPolicies` is beta-only. Recheck whether it reaches v1.0.
- **Scripts and custom attributes on Graph beta (Microsoft):** both are beta. Recheck whether they reach v1.0.
- **ADE settings on Graph beta (Microsoft):** beta only (MDM authority and the APNs certificate are read from v1.0). Recheck whether they reach v1.0.
- **Checked live on 2026-11-03 (Microsoft), release check on the Intune test tenant:** a Settings Catalog PUT with its settings inline updates the policy (the changed setting reads back, the next Plan has nothing to do), and its `assign` body is accepted and reads back. A `$filter` on `configurationSettings` is refused (HTTP 400), so the app reads the setting IDs unfiltered and paged; the live check requires that read to be answered. Recheck if Microsoft documents either route or the PUT stops accepting inline settings.
- **Still unverified, marked `TODO(verify)` in code (Microsoft):** exclusions alongside mixed Required/Available app intents. The live check assigns only to its one empty test group (never All users or an existing group), so it can't build that case; verify on a test tenant by hand.
- **`.ipa` upload (Microsoft):** still unverified (`TODO(verify)`) and labeled "preview" in the README until a real signed `.ipa` deployment confirms it.
- **App content check (Microsoft), checked live on 2026-11-02:** Plan relies on the `mobileApps` list returning `committedContentVersion` and the committed file returning `size`; both do (`.pkg` tested; `.dmg` and `.ipa` use the same fields), so an unchanged app isn't uploaded again. Graph doesn't return `sizeInBytes` on the file; since 1.7.0 the app reads `size` first. Recheck if Microsoft drops `size` (a file without a size counts as this package, so the check would stop catching a failed upload).
