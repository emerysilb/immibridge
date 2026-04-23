# Issue #15: Fix Battery Crash on Launch

## Goal
Fix the crash that occurs when ImmiBridge is launched while on battery power with "Skip on battery" enabled.

## Root Cause
Infinite recursion / stack overflow in `BackupScheduler.swift`. When the app launches with an overdue scheduled backup while on battery:

1. `bind(to:)` (called from `ContentView.onAppear` line 134) calls `reschedule()`
2. `reschedule()` (line 281) sees the backup is overdue (`interval <= 0` at line 297) and calls `triggerScheduledBackup()`
3. `triggerScheduledBackup()` (line 365) detects battery power at line 376 and calls `reschedule()` again at line 379
4. `reschedule()` recalculates `calculateNextBackupDate()` which for `.interval` mode (line 318-320) returns `lastBackupDate + intervalHours` -- still in the past
5. Back to step 2. Infinite loop. Stack overflow crash.

## Files to Modify
- `ImmiBridge/ImmiBridge/UI/BackupScheduler.swift` -- this is the ONLY file that needs changes

## Exact Fix Required

In `triggerScheduledBackup()` around line 376-381, when battery is detected and backup is skipped, you must NOT call `reschedule()` directly (which re-enters the overdue check). Instead:

**Option A (preferred):** Before calling `reschedule()`, update `lastBackupDate = Date()` so the next `calculateNextBackupDate()` returns a future time:
```swift
if skipOnBattery && !PowerManager.isOnACPower() {
    NotificationManager.shared.sendBackupSkipped(reason: "Mac is on battery power")
    lastBackupDate = Date()  // Advance to break the overdue loop
    saveSettings()
    reschedule()
    return
}
```

**Option B:** Add a re-entrancy guard flag to `reschedule()` to prevent recursive invocation.

**Option C:** In the overdue branch of `reschedule()` (line 297-300), advance `lastBackupDate` to `Date()` before calling `triggerScheduledBackup()`.

## Constraints
- Do NOT change how `PowerManager.isOnACPower()` works -- it's fine
- Do NOT remove the "skip on battery" feature
- Do NOT change the scheduled/interval backup logic beyond fixing the recursion
- The fix must handle BOTH `.interval` and `.scheduled` schedule types
- Keep the notification (`sendBackupSkipped`) so the user knows the backup was skipped

## Verification
1. The app must build without errors: `xcodebuild -project ImmiBridge/ImmiBridge.xcodeproj -scheme ImmiBridge -configuration Debug build`
2. Read through `reschedule()` and `triggerScheduledBackup()` and confirm there is no possible call cycle that lacks a termination condition
3. Verify `calculateNextBackupDate()` will return a future date after your fix is applied

## Completion
When the fix is implemented and the build succeeds, output:
<promise>ISSUE 15 FIXED</promise>
