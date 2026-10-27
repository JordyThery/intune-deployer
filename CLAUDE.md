# Intune Deployer: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app is

- A macOS app that populates one Microsoft Intune tenant from a baseline: a local folder or GitHub repository of plain files (Settings Catalog/compliance/filter JSON, `.mobileconfig`, shell scripts, custom attributes, `.pkg`/`.dmg`/`.ipa`). No XML manifests, no PowerShell, no Graph SDK.
- It talks to Microsoft Graph directly, signs in interactively with MSAL (through JTKit's `JTKitMSAL`), and shows a read-only Plan before anything is written.
- Jordy is not a programmer: explain changes in plain language and work in small steps.

## How to work on it

- App-only work: open the app's own project (`Intune Deployer.xcodeproj`). Its notes load and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Build releases from the app's own project. Never have the app open in both at once.
- Only change JTKit or other apps when Jordy asks for them.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- The project uses filesystem-synchronized groups: new files under `Intune Deployer/` are picked up automatically. Don't edit `project.pbxproj` by hand; Jordy changes package references in Xcode.

## Rules decided by Jordy

- **Single-tenant focus.** Features work on one active tenant at a time. Don't propose cross-tenant plans or applies, tenant comparison or bulk multi-tenant work.
- **One app registration per tenant.** Every tenant profile carries its own client ID and tenant ID (single-tenant, public client, no secret) and its own signed-in account. Never introduce a global client ID. Settings shows only the shared values (bundle ID, redirect URI).
- **Audience-neutral wording** in UI text, tooltips, code comments and README: no "customer", "MSP" or "partner". Say "tenant", "the target tenant" or "organization".
- **Copyright** is exactly "© 2026 Jordy Thery" (JTKit's About writes the line).
- **The app does not link to community baselines** (intune-my-macs, OpenIntuneBaseline). The README may mention them as places to get files.
- **Item edits:** an edit overrides a file's content inside the app only. Never write it back to the file or push it to GitHub. The editor shows JSON pretty-printed but otherwise as-is: don't strip or transform content.
- **Tenant export** lives only in the tenant view, never in the Plan view. App packages are skipped (Graph can't download content).
- Deferred on purpose, not new ideas: taking over untagged objects ("adopt"), drift check, plan export.
- Rejected: CI pipelines (Jordy runs tests locally and releases by hand), a README demo GIF, streaming uploads for very large installers.

## Architecture

- `Core/`: inference (`InferenceEngine`, JSON, mobileconfig, script directives `# intune:`, `AppPackageInspector`), item models, `ItemIdentity`.
- `Engine/`: pure, no network. `PlanEngine` (matching, diff, assignment resolution, order), `PayloadBuilder`, `GraphDiff`, `SettingsCatalogDiff`, `AppEncryptor`, `AppContentUploader`, `TenantExporter`, `AsBuiltReport`, `DeletionConfirmations`, variables.
- `Graph/`: Graph models, `PreflightService`.
- `Auth/AuthManager.swift`: per-tenant sign-in state and the app's Graph scopes, on `JTKitMSAL`.
- `Sources/`: baseline sources, `SourceStore` (single choke point `fileContents(of:)` that overlays edits), `GitHubClient`, `GitHubTokenStore`, `ItemEditStore`, `PlatformOverrideStore`.
- `Tenants/`: `TenantProfile`, `TenantStore`, `TenantSession` (+Deploy, +Export).
- `UI/`: the screens, `GuidedTour.swift` (steps only).

From JTKit: `Graph.Client` (retries, paging, errors, 4 requests at a time), `JTKitMSAL` / `MicrosoftSignIn`, `RequestRecorder` (Azure Storage upload, GitHub), `ActivityLog` + `ActivityLogWindow`, `ConnectionStore` + `ConnectionPicker` + `ConnectionCommands`, `KeychainSecretStore`, `SettingsWindow`, `AboutWindow` + `Acknowledgement.msal`, `UpdateChecker`, `TourState`/`TourStep`, `TextExportDocument`, `JSONFile`; `JTKitTestSupport` (`MockServer`) in tests.

Stays in the app: the plan and apply engine, diffing, identity tags, payloads, app encryption and upload, export, preflight, GitHub sources, its Graph scopes, the Keychain group in its entitlements. Extend JTKit instead of adding another copy of anything it has.

## Stored data (keep these names)

- Tenant profiles: `tenants.json` in Application Support/Intune Deployer, through JTKit's `ConnectionStore`; selection in UserDefaults `selectedTenantProfileID`. Settings › Connections changes only name, tenant ID and client ID; the main window saves only the baseline part.
- Item edits, platform overrides and the GitHub cache (`GitHubSources/<sourceID>/`) in Application Support/Intune Deployer.
- GitHub token: Keychain service `be.jordythery.intune-deployer.github`, account `personal-access-token`, "when unlocked"; trimmed, empty deletes.
- The app's own Keychain group must stay listed before MSAL's in the entitlements, so new items don't land in MSAL's shared group. MSAL keeps its own token cache.
- UserDefaults `enableItemEditing` (off by default), `hasSeenGuidedTour`.

## Graph behaviour learned the hard way

- Identity tag `[IntuneDeployer:<8 hex>]` in the description; an empty description becomes "Managed by Intune Deployer [tag]". Legacy `[gw:…]` is still matched on read, never written. Matching is tag + `@odata.type`: a platform change means create + orphan.
- Apply order: filters → custom attributes → scripts → apps → custom configurations → Settings Catalog → compliance; assignments last.
- Settings Catalog (`configurationPolicies`) is beta-only and uses `name`. Child settings need their parent group setting instance in the payload (macOS and iOS).
- Compliance: `scheduledActionsForRule` is required on create; updates go through `POST {id}/scheduleActionsForRules`. Read with `$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)`. The service stores rule names as null (ignored in the diff).
- Scripts and custom attributes are beta; content is base64. List answers omit `scriptContent`, so fetch tagged objects one by one. Intune normalises `executionFrequency` (PT1440M becomes P1D): emit the canonical form. Assign body key is `deviceManagementScriptAssignments`. Custom attribute name/type are immutable (stripped on PATCH, ignored in the diff) and often returned null.
- Assignment filters don't apply to shell scripts, custom attributes or filters themselves; the plan strips them with a warning.
- Groups: `displayName eq` filter needs no ConsistencyLevel; `mailNickname` max 64 restricted ASCII.
- MDM authority via v1.0 `organization/{id}?$select=mobileDeviceManagementAuthority`; APNs certificate v1.0; ADE settings beta. Only 429 is documented with `Retry-After`.
- App upload: content version → file (`manifest: null`) → poll `azureStorageUriRequestSuccess` → 6 MiB blocks + block list (`renewUpload` when the SAS expires) → commit with encryption info → poll `commitFileSuccess` → PATCH `committedContentVersion` → wait for `publishingState == published` before `/assign`. Content is re-uploaded only when bundle version, build number, file name or (for `.ipa`) provisioning expiry changes. The commit body holds the encryption key: never recorded (JTKit).
- Retries follow JTKit's rules. Updates, `/assign`, `scheduleActionsForRules` and deletes are safe to repeat; creates never are (a new Plan finds a created object by its tag).
- MSAL: consent sheets must anchor to the key window (now handled in `JTKitMSAL`); scopes are asked step by step (read at sign-in, write at first Apply, `Group.ReadWrite.All` only when group creation is on).
- Still unverified (marked `TODO(verify)` in code): Settings Catalog PUT with inline settings and its assign body, `configurationSettings` `$filter`/`$top`, exclusions alongside mixed Required/Available app intents, the `.ipa` upload (labelled "preview" in the README until a real signed `.ipa` deployment confirms it).

## Swift and testing gotchas

- Swift 6 with default MainActor isolation: engine and core types are explicitly `nonisolated`. A cached `static let` Regex isn't Sendable; build regexes locally.
- Swift Testing: write `#expect(try f() == x)`, not `try #expect(…)`; use closures instead of key paths as functions inside `#expect`.

## Testing

- Unit tests: ⌘U in the app's own project (Swift Testing, hosted in the app). Graph, GitHub and upload tests run on JTKit's `MockServer`; the GitHub token test uses a fake store, never the real Keychain.
- The test target needs the same development team as the app, or the hardened runtime blocks the hosted test bundle.
- On this Mac, Intune Deployer is signed in only to the demo tenant (it is on the local allow-list). Never sign it in to another tenant: `LiveTenantTests` use whichever tenant is signed in.
- `LiveTenantTests` (serialized) reuse the app's saved profiles and MSAL cache and skip when nobody is signed in. The read-only dry run runs whenever possible. The write lifecycle runs only with `INTUNE_DEPLOYER_LIVE_WRITE=1` (or the `LiveWriteTests` default); it creates `[AUTOTEST]`-prefixed objects and deletes only those. Don't enable it unless Jordy asks.
- Never run the long UI suites of Jamf Deployer and AppSettings2Blueprint unless Jordy asks for a test by name (JTKit rule).
- Release check and live sandbox checks: see JTKit ROADMAP step 11. Tenants come only from the local allow-list outside git; never name a tenant in this repo.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (both app configurations). Update the JTKit package version first if needed.
2. Keep `THIRD-PARTY-NOTICES.md` in line with JTKit's MSAL version (a test checks it).
3. Follow the release gate in JTKit/ROADMAP.md (release check, design review, code review, Jordy's check by hand).
4. Commit, tag `vX.Y.Z`, create a draft GitHub release with short, professional notes.
5. Jordy archives, signs and notarizes. Verify (`codesign`, `spctl`, `stapler`), zip with `ditto -c -k --keepParent` as `Intune.Deployer.X.Y.Z.app.zip`, upload, publish.
6. Every release needs the `.zip` asset: the in-app updater reads `releases/latest`. Re-download and check with `spctl` after publishing.
7. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.
