# Intune Deployer: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Settings Catalog on Graph beta (Microsoft):** `configurationPolicies` is beta-only. Recheck whether it reaches v1.0.
- **Scripts and custom attributes on Graph beta (Microsoft):** both are beta. Recheck whether they reach v1.0.
- **ADE settings on Graph beta (Microsoft):** beta only (MDM authority and the APNs certificate are read from v1.0). Recheck whether they reach v1.0.
- **Still unverified, marked `TODO(verify)` in code (Microsoft):** Settings Catalog PUT with inline settings and its assign body; `configurationSettings` `$filter`/`$top`; exclusions alongside mixed Required/Available app intents. Verify against a real tenant.
- **`.ipa` upload (Microsoft):** still unverified (`TODO(verify)`) and labelled "preview" in the README until a real signed `.ipa` deployment confirms it.
