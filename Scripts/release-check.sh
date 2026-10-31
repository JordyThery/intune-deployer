#!/bin/zsh
# Intune Deployer's release check (JTKit ROADMAP step 11). Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   Scripts/release-check.sh [--local-jtkit] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|all-devices-attempt|saved-tenant-attempt
#     (tests the check itself; never part of a release check)
#
# One tenant, a role on the local allow-list (never named here): intune-test,
# create and remove. Its sign-in is the app's saved Microsoft sign-in (MSAL's
# cache), matched by tenant ID; no Keychain item is read by the script. Every
# other saved tenant gets no request at all.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Intune Deployer"
APP_CODE="ID"
PROJECT="Intune Deployer.xcodeproj"
SCHEME="Intune Deployer Release Check"
UNIT_TESTS="Intune DeployerTests"
UI_TESTS="Intune DeployerUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Intune DeployerUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Intune DeployerTests/LiveSignInTests"
LIVE_TESTS=(
    "Intune DeployerTests/LiveLifecycleTests/baseline()"
)
CLEANUP_TEST="Intune DeployerTests/LiveCleanupTests"
# MSAL's cache and the GitHub token, seen from the test host (names as hashes).
HOST_KEYCHAIN_TEST="Intune DeployerTests/LiveHostKeychainTests"
ROLES=(intune-test)
CREDENTIALS=()
# all-devices-attempt: the app's Apply assigns to All devices (must be refused);
# saved-tenant-attempt: the app asks for a saved tenant's token (must be refused).
APP_FAULTS=(all-devices-attempt saved-tenant-attempt)
DOMAIN="be.jordythery.intune-deployer"
CONTAINER="$HOME/Library/Containers/$DOMAIN/Data"
# The app is sandboxed: its test host reaches only its own container, so the
# live folder (allow-list copy, ledger, results) lives there (JTKit 0.12.2).
TEST_HOST_CONTAINER="$DOMAIN"
# The saved tenants, the one in use and three settings (hashes only).
FINGERPRINT_PATHS=("$CONTAINER/Library/Application Support/Intune Deployer/tenants.json")
FINGERPRINT_DEFAULTS=()
for key in selectedTenantProfileID enableItemEditing hasSeenGuidedTour demoMode; do
    FINGERPRINT_DEFAULTS+=("$CONTAINER/Library/Preferences/$DOMAIN $key")
done
# Keychain item names come from the test host (HOST_KEYCHAIN_TEST), as hashes.
KEYCHAIN_PREFIXES=()

# Under tests the app refuses every request to a saved tenant or GitHub and
# writes the attempt here; the live checks fail the run if it isn't empty.
# A new run starts with no attempts.
rm -rf "$CONTAINER/tmp/IntuneDeployer-under-test"

# The template comes from the JTKit under test: the local checkout with
# --local-jtkit, otherwise the published version this project resolves.
if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.5 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
