# Changelog

## 1.7.0 (2026-11-03)

### New
- When Microsoft asks the app to wait before trying again, the wait is shown with a Stop button. Stop ends the wait; Apply and Remove Baseline then send nothing after it.
- A new or imported tenant profile becomes the one in use when no tenant is in use yet.
- Settings › Connections says when a tenant ID is neither a tenant ID nor a domain.
- A new app icon in the macOS icon shape.

### Changed
- Tenants are compared by the tenant ID Microsoft’s sign-in names, so a profile with the tenant’s domain and one with its tenant ID count as the same tenant. This also applies to recognizing objects deployed before version 1.6 by a profile without a naming prefix.
- The as-built report masks a variable’s value only where the variable is used, so the same text elsewhere in a payload stays readable. Scripts and profiles with variables are now shown masked instead of left out.
- Reading a large app package at plan time gets more time (five minutes plus a minute per GB), and a package that takes longer says so.

### Fixed
- Plan no longer sends failing assignment requests for assignment filters.
- A Keychain that can’t be read is reported as such, instead of as a missing GitHub token.
- The tenant check uses the tenant Microsoft reports with each sign-in token.

## 1.6.1 (2026-11-01)

### Fixed
- Objects deployed by version 1.5 or earlier are recognized again by Remove Baseline and the orphan list when the tenant profile has no naming prefix and is the only tenant profile for its tenant. The next Apply of each item adds the profile tag.

## 1.6.0 (2026-11-01)

### New
- Demo Mode: try the app on “Contoso Intune (Demo)”, a sample tenant inside the app. Plan, Apply, Remove Baseline, tenant export and Preflight run for real against it; nothing is sent to a real tenant.
- Tenant profiles live in Settings › Connections, with a tenant picker in the toolbar and a Connection menu.
- Baseline Settings warns when another tenant profile uses the same naming prefix: objects deployed before profile tags are matched by it.

### Safer writes
- Every request to a tenant is sent only with a sign-in token of that tenant profile’s tenant; otherwise nothing is sent and Apply says which tenant it was. A profile with a verified domain is confirmed against that tenant’s verified domains before its first read. A saved sign-in is no longer tied to a tenant just because it’s the only account on the Mac.
- Apply refuses a plan made for another tenant profile or tenant ID, and does nothing while another Plan or Apply runs; Remove Baseline too.
- Apply refuses a plan with errors. An item that fails to build no longer shows its tenant object as an orphan.
- Apply with two or more ticked deletions asks you to type the number of deletions first.
- Orphans and Remove Baseline cover only the tenant profile’s own objects. New and updated objects carry the profile’s tag (`[IntuneDeployerProfile:…]`) next to the identity tag; objects deployed before count as the profile’s when their name carries its naming prefix. The first Plan after updating shows each existing object as an update once (its description gains the profile tag).
- Groups and built-in template filters the app creates carry the profile’s tag. Remove Baseline deletes those filters, and a group only when it carries the profile’s tag and has no members; every other group the profile’s assignments name is listed and kept. Remove Baseline deletes only what it counted, and asks for permission to delete groups when it needs it.
- Plan doesn’t run while a chosen item may be in a source that isn’t scanned (a failed sync, a drive that isn’t mounted), so its object isn’t offered for deletion. Plan is disabled while sources are scanning.
- The tenant in use can’t be switched while a Plan, Apply or Remove Baseline runs, and a switch never loses results.
- New assignment targets and per-type defaults start as a group still to be named; All devices and All users are always an explicit choice.

### Assignments and apps
- Assignments are compared with the tenant’s: Apply sends only those that differ, and an unchanged baseline shows “Everything is already up to date”.
- Renamed filters are assigned in the same Apply.
- Several groups with the same name are a plan error instead of the first one being used.
- A tenant filter that names no platform is a plan error instead of being assigned unchecked.
- An app update uploads the package before writing the new version. Plan notices a package that never arrived and uploads it again.
- Plan shows “Apply uploads the package (size)”, and Apply refuses a package that changed since the Plan.
- App uploads run off the main thread, and a disk image’s license prompt can’t hang Plan.
- Custom attributes keep `runAsAccount=user`.

### Sources, edits and saved data
- Items keep their identity when a source is removed and added again, and when a tenant profile is imported on another Mac: exports carry the sources’ identities. If the source is already on the other Mac, the profile’s choices move to it and Plan updates the deployed objects.
- Unreadable `sources.json`, `item-edits.json` and `platform-overrides.json` files are copied aside and never saved over; an alert says so.
- The editor shows content as it is: one-line JSON is indented and keys keep their order. Binary profiles and files that aren’t UTF-8 text are refused instead of converted.
- An edit whose file disappears is kept until it’s reverted.
- A misspelled `# intune:` key is shown with the item’s detection.
- Settings › GitHub says when the Keychain refused to save or remove the token.

### Reports, export and Preflight
- Tenant export removes the profile tag.
- The as-built report masks variable values and uses words instead of emoji.
- The results line counts skipped steps.
- Default file names never contain “/” or “:”.
- Preflight: a push certificate that can’t be read is a warning instead of “none”, and an ADE token without an expiry date gets a warning row.
- Apple Business and Apple Account wording throughout.

### Release check
- The live check requires that a second Apply of an unchanged baseline sends nothing.

## 1.5 (2026-10-23)

### New
- Multiple assignment targets: any combination of All devices, All users and groups, each with its own filter and install intent.
- Group exclusions. Including and excluding the same group is a plan error.
- Readable Settings Catalog changes: Plan lists changed settings by name and value, with a Raw view for the JSON diff.

### Improvements
- Reordered Settings Catalog settings are no longer reported as changes.
- A target that can’t be resolved blocks the item’s assignment change instead of applying a partial set.
- Per-type default assignments support multiple targets and exclusions.

## 1.4 (2026-10-17)

### New
- iOS/iPadOS support for Settings Catalog, compliance, custom configuration profiles and assignment filters. `.mobileconfig` profiles default to macOS, with a per-item Platform picker and Set Platform for several items.
- iOS apps (`.ipa`, preview): signed packages upload as iOS LOB apps, with a warning before the provisioning profile expires.
- Install intent for apps: Required (default) or Available in Company Portal.
- Tenant export includes iOS/iPadOS objects, grouped by platform and type.

### Fixed
- iOS Settings Catalog policies no longer fail setting validation.
- Changing an item’s platform after deployment plans a create, with the old object offered for deletion.

## 1.3 (2026-10-16)

### New
- Tenant export: export existing objects from the tenant view as baseline files the app reads back. Read-only fields, the identity tag, the naming prefix and assignments are removed; app packages are skipped and existing files are never overwritten.

### Fixed
- Custom configuration profiles with a variable in `PayloadDisplayName` get the substituted name in Intune.

## 1.2 (2026-10-15)

### New
- Item editing: edit an item’s content (except app packages) inside the app. Edits deploy instead of the file; the source file is never modified. Edits clear themselves when the source catches up and are flagged when it changes differently.

### Fixed
- Assignment filters can no longer be given assignments.
- Bulk actions apply only to visible items.
- Overlapping scans or syncs of the same source no longer overwrite each other’s results.
- Hardening: symlinks in downloaded repositories are removed, update URLs are restricted to GitHub over HTTPS, and path traversal is rejected in package metadata and source subfolders.

## 1.1 (2026-10-15)

### New
- Multi-selection in the item list, bulk include/exclude and a Selection toolbar menu.
- Bulk assignment editing for several items at once.
- Default assignments per item type, set in the tenant profile.
- Guided tour on first launch, replayable from Help › Guided Tour.

### Fixed
- Assignment filters are no longer offered on shell scripts and custom attributes, where Intune doesn’t support them; stored ones are dropped at plan time with a warning.

## 1.0.1 (2026-10-15)

- Update checker: the app checks GitHub at most once a day for a newer release (Intune Deployer › Check for Updates…, or off in Settings › Updates).

## 1.0 (2026-10-15)

- First release: deploys macOS configuration to Microsoft Intune from plain files (Settings Catalog JSON, `.mobileconfig` profiles, compliance policies, shell scripts, custom attributes, assignment filters and `.pkg`/`.dmg` apps), with a dry-run Plan, identity tags, one profile per tenant, Preflight, tenant inventory, as-built reports and tenant profile export and import.
