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
- The app's own Keychain group must stay listed before MSAL's in the entitlements (a test checks the signed app), so a new data-protection Keychain item that names no group never lands in MSAL's shared group. MSAL names its own group, so its sign-in cache is found either way. The GitHub token is in the login Keychain, where these groups don't apply.
- UserDefaults `enableItemEditing` (off by default), `hasSeenGuidedTour`, `demoMode`.

## Demo Mode (JTKit step 10, decided by Jordy)

- "Contoso Intune (Demo)" on JTKit's demo Intune server (`AppDemo`, `TenantProfile.demo`). Plan, Apply, deletions, Remove Baseline, export, uploads and Preflight run the real code against it, with their real confirmations.
- The demo tenant never reaches MSAL: `AuthManager` answers it with `DemoMode.microsoftSignIn()` (fixed token, sample account) and never sets up `MicrosoftSignIn` for it (tested with a trap). Its client uses the demo network's session only.
- Its baseline lives in memory per launch (`TenantStore.demoProfile`); `tenants.json` and `selectedTenantProfileID` are never written in demo mode. An exported demo tenant is refused on import, under any ID.
- Stay real: baseline sources, item edits, platform overrides, the GitHub cache. The GitHub token is read but can't be changed in demo mode.
- Before a demo Plan the demo catalog learns the setting IDs the selected Settings Catalog items use, so a typo in a setting ID isn't caught in demo mode. A tagged left-over ("Contoso – Legacy Wi-Fi") makes the first Plan show a deletion.
- `-JTKitDemoScenario missingPermission`: every write gets Graph's real 403. `-JTKitSandbox YES`: tenants and sources in demo mode's temporary folder, no update check, GitHub blocked.

## Graph behaviour learned the hard way

- Identity tag `[IntuneDeployer:<8 hex>]` in the description, then the profile tag `[IntuneDeployerProfile:<8 hex>]` (SHA-256 of the profile ID; since 2026-10-30, a separate tag so older builds still read the item tag); an empty description becomes "Managed by Intune Deployer [tags]". Legacy `[gw:…]` is still matched on read, never written. Matching is tag + `@odata.type` (any profile): a platform change means create + orphan. Orphans and Remove Baseline cover only the profile's objects: its profile tag, or (deployed before profile tags) a name with its non-empty naming prefix. Created groups and template filters carry "Created by Intune Deployer…" and the profile tag; Remove Baseline deletes those filters and the groups the profile's intents name if they have no members.
- Every token of a real tenant is checked before anything is sent with it (`TenantCheck`): its `tid` must be the profile's tenant ID; a profile with a verified domain is confirmed once before writes (`TenantSession.writeClient`: the token's `organization` lists the domain). Accounts are restored by saved identifier, or by exact home tenant for a tenant ID, never "the only account". Apply refuses a plan made for another profile or tenant ID, and does nothing while a Plan or Apply runs.
- Plan reads the assignments of the matched objects (`…/assignments`; custom attribute scripts answer 400 there, so `?$expand=assignments`) and compares them with what Apply would send (`AssignmentBody`, `AssignmentEntry`); Apply sends only differing ones. Unreadable assignments are sent. A created app without committed content plans an upload again. Several groups with one name, and a tenant filter without a platform, are plan errors.
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
- **Under tests** (the unit-test host and a sandbox launch; `Tenants/UnderTest.swift`, decided by Jordy, JTKit step 11): the app reaches no saved tenant and no GitHub repository. `AuthManager` refuses every saved tenant's sign-in, token and sign-out before MSAL is set up, `TenantSession` gives a real tenant a network that refuses everything, and `SourceStore`'s GitHub network refuses too; each attempt is written to the container's `tmp/IntuneDeployer-under-test/` and fails the release check. The unit-test host starts like a sandbox run: tenants, sources, edits, platform choices and the GitHub cache in a temporary folder (`UnderTest.dataFolder`), settings and the tour's "seen" setting in a temporary file, no update check, demo mode off and never saved. Tests make settings with `TestSettings.makeDefaults` (a file in the test process's temporary folder), never `UserDefaults(suiteName:)` (that left a file in Preferences per test). Tests of the guard use a guard file of their own, never the shared one.
- **Live checks** (`LiveCheckTests.swift`) run only from the release check (`Scripts/release-check.sh`, scheme "Intune Deployer Release Check"); ⌘U skips them and the app's own scheme runs the unit tests only. Only on the allow-listed Intune test tenant (role `intune-test`): the saved Microsoft sign-in of the one saved profile with its tenant ID (matched strictly, MSAL's cache only; when MSAL needs its window the run stops and says to sign in once in the app). A `JTKTEST ID` baseline (filter, shell script, custom attribute, Settings Catalog, compliance with "block" only) is applied with the app's own Plan and Apply behind a fence, read back, planned again (nothing to do), updated once, and removed with the app's own deletion path (orphans ticked, only this run's); assignments only to one empty `JTKTEST` group the run creates (0 members checked first), never All devices, All users or an existing group (JTKit's guarded network refuses them too). The group is removed and emptied from Entra's recycle bin. Old `[AUTOTEST]` objects were swept once. No device actions. `UI tests`: `DemoSmokeUITests` only.
- The live check requires that a second Apply of an unchanged baseline sends nothing (assignments are compared since 2026-10-30).
- Never run the long UI suites of Jamf Deployer and AppSettings2Blueprint unless Jordy asks for a test by name (JTKit rule).
- Release check: see JTKit ROADMAP step 11. Tenants come only from the local allow-list outside git; never name a tenant in this repo. Never sign the app in to a tenant other than the Intune test tenant on this Mac.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (both app configurations). Update the JTKit package version first if needed.
2. Keep `THIRD-PARTY-NOTICES.md` in line with JTKit's MSAL version (a test checks it).
3. Follow the release gate in JTKit/ROADMAP.md (release check, design review, code review, Jordy's check by hand).
4. Commit, tag `vX.Y.Z`, create a draft GitHub release with short, professional notes.
5. Jordy archives, signs and notarizes. Verify (`codesign`, `spctl`, `stapler`), zip with `ditto -c -k --keepParent` as `Intune.Deployer.X.Y.Z.app.zip`, upload, publish.
6. Every release needs the `.zip` asset: the in-app updater reads `releases/latest`. Re-download and check with `spctl` after publishing.
7. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.
