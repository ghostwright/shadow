#!/bin/bash
# Reset Shadow's TCC permissions, quit, and relaunch with System Settings open.
#
# WHY: Each ad-hoc rebuild changes the binary signature, which invalidates
# the macOS TCC entries. The old entries show as "granted" in System Settings
# but the APIs return false because the code signature no longer matches.
#
# WHEN TO RUN: After every build that changes the binary (i.e., every rebuild
# during development with ad-hoc signing). Not needed for production builds
# with a stable signing identity.
#
# WHAT IT DOES:
#   1. Quits Shadow gracefully (if running)
#   2. Resets all 5 TCC entries for Shadow
#   3. Launches Shadow.app from DerivedData
#   4. Opens each System Settings pane in sequence so you can grant permissions
#
# USAGE:
#   scripts/reset-permissions.sh           # reset + quit + relaunch
#   scripts/reset-permissions.sh --reset   # reset only (no quit/relaunch)

set -euo pipefail

BUNDLE_ID="com.shadow.app"
RESET_ONLY=false

if [[ "${1:-}" == "--reset" ]]; then
    RESET_ONLY=true
fi

# --- Step 1: Quit Shadow if running ---
if ! $RESET_ONLY; then
    if pgrep -x Shadow >/dev/null 2>&1; then
        echo "Quitting Shadow..."
        osascript -e 'tell application "Shadow" to quit' 2>/dev/null || true
        sleep 2
        # Force kill if still running
        if pgrep -x Shadow >/dev/null 2>&1; then
            kill "$(pgrep -x Shadow)" 2>/dev/null || true
            sleep 1
        fi
        echo "  Shadow stopped."
    else
        echo "Shadow is not running."
    fi
    echo ""
fi

# --- Step 2: Reset all TCC entries ---
echo "Resetting TCC permissions for $BUNDLE_ID..."
echo ""

tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null && \
    echo "  Screen Recording: reset" || \
    echo "  Screen Recording: already clean"

tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null && \
    echo "  Accessibility: reset" || \
    echo "  Accessibility: already clean"

tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null && \
    echo "  Input Monitoring: reset" || \
    echo "  Input Monitoring: already clean"

tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null && \
    echo "  Microphone: reset" || \
    echo "  Microphone: already clean"

tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null && \
    echo "  Speech Recognition: reset" || \
    echo "  Speech Recognition: already clean"

# Reset ALL onboarding-related UserDefaults for a clean-slate flow.
#
# Key inventory (every key written by onboarding views):
#   onboardingCompleted                          -- gates whether onboarding shows (AppDelegate)
#   onboardingStep                               -- which step to resume at (OnboardingContainerView)
#   onboardingScreenRecordingGrantedDuringSession -- restart-flow flag (PermissionsStepView)
#   onboardingModelTestPassed                    -- whether AI test succeeded (ModelSetupStepView)
#   llmCloudConsentGranted                       -- consent gate for CloudLLMProvider
#   llmMode                                      -- auto/cloud/local/skip (ModelSetupStepView)
#   launchNotificationShown                      -- one-time "Shadow is watching" notification
ONBOARDING_KEYS=(
    onboardingCompleted
    onboardingStep
    onboardingScreenRecordingGrantedDuringSession
    onboardingModelTestPassed
    llmCloudConsentGranted
    llmMode
    launchNotificationShown
)

for key in "${ONBOARDING_KEYS[@]}"; do
    defaults delete "$BUNDLE_ID" "$key" 2>/dev/null && \
        echo "  $key: reset" || \
        echo "  $key: already clean"
done

echo ""

if $RESET_ONLY; then
    echo "Reset complete (--reset mode, no relaunch)."
    exit 0
fi

# --- Step 3: Find and launch Shadow.app ---
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Shadow-*/Build/Products/Debug/Shadow.app -maxdepth 0 2>/dev/null | head -1)

if [[ -z "$APP_PATH" ]]; then
    echo "Shadow.app not found in DerivedData. Build first:"
    echo "  xcodebuild -project Shadow/Shadow.xcodeproj -scheme Shadow -configuration Debug build"
    exit 1
fi

echo "Launching $APP_PATH..."
open "$APP_PATH"
echo ""

# --- Step 4: Open System Settings panes ---
# Brief pause to let Shadow launch and trigger its first permission prompt
sleep 2

echo "Opening System Settings for permission grants..."
echo ""

# Open Screen Recording first (most critical — requires relaunch after grant)
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

echo "Grant permissions in this order:"
echo ""
echo "  1. Screen Recording  -- toggle Shadow ON (requires relaunch after)"
echo "  2. Accessibility      -- click +, find Shadow, add it"
echo "  3. Input Monitoring   -- click +, find Shadow, add it"
echo "  4. Microphone         -- toggle Shadow ON (required, for audio capture)"
echo "  5. Speech Recognition -- toggle Shadow ON (required, for transcription)"
echo ""
echo "After granting Screen Recording, quit and relaunch Shadow:"
echo "  osascript -e 'tell application \"Shadow\" to quit'"
echo "  open \"$APP_PATH\""
echo ""
echo "Verify permissions are active:"
echo "  /usr/bin/log show --predicate 'process == \"Shadow\"' --last 30s --style compact"
