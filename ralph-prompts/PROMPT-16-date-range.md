# Issue #16: Date Range Improvement

## Goal
Improve the date range filter so the "To" date defaults to "now" (today) and add a "Last X days" shortcut option.

## Problem
The `filterEndDate` is persisted to UserDefaults (`PhotoBackupViewModel.swift` line 615). After first launch, it stays at whatever date was last saved. Users expect "To" to mean "up to now" but it's stuck on a stale date, causing them to re-sync their entire library or miss recent photos.

## Files to Modify
1. `ImmiBridge/ImmiBridge/UI/PhotoBackupViewModel.swift` -- ViewModel state and persistence
2. `ImmiBridge/ImmiBridge/UI/ContentView.swift` -- Date filter UI (around lines 377-395)

## Changes Required

### 1. Add a "relative date" mode (ViewModel)

Add new published properties to `PhotoBackupViewModel` (near line 118-120):
```swift
@Published var useRelativeDateRange: Bool = false
@Published var relativeDaysBack: Int = 30
```

Persist/restore these in `loadSettings()` (line 257 area) and `saveSettings()` (line 614 area).

### 2. Stop persisting filterEndDate when in relative mode

When `useRelativeDateRange` is true, compute dates dynamically instead of using stored dates. In the options builder (line 705-706), compute:
```swift
let computedStartDate: Date
let computedEndDate: Date
if useRelativeDateRange {
    computedEndDate = Date()
    computedStartDate = Calendar.current.date(byAdding: .day, value: -relativeDaysBack, to: computedEndDate) ?? computedEndDate
} else {
    computedStartDate = filterStartDate
    computedEndDate = filterEndDate
}
```

Then use `computedStartDate` and `computedEndDate` in the `since:` and `until:` parameters.

### 3. Update the UI (ContentView)

In the date filter section (lines 377-395 of `ContentView.swift`), add a picker above or below the toggle:

```swift
if model.dateFilterEnabled {
    Picker("Mode", selection: $model.useRelativeDateRange) {
        Text("Custom Range").tag(false)
        Text("Last X Days").tag(true)
    }
    .pickerStyle(.segmented)

    if model.useRelativeDateRange {
        Stepper("Last \(model.relativeDaysBack) days", value: $model.relativeDaysBack, in: 1...3650)
    } else {
        // existing DatePicker("From"...) and DatePicker("To"...) here
    }
}
```

### 4. Always reset filterEndDate to today on load

Regardless of mode, when loading settings in `loadSettings()`, after restoring `filterEndDate` from UserDefaults (line 262-263), reset it:
```swift
filterEndDate = Date()  // Always default "To" to today
```

This ensures even in "Custom Range" mode, the end date starts at today on each launch.

## Constraints
- Do NOT break existing date range filtering behavior
- Do NOT change how `since`/`until` are applied in the backup core
- Keep the existing `DatePicker` controls for custom range mode
- Match the existing UI style (SwiftUI, same section layout)
- Disable controls while `model.isRunning`

## Verification
1. Build succeeds: `xcodebuild -project ImmiBridge/ImmiBridge.xcodeproj -scheme ImmiBridge -configuration Debug build`
2. Review the date filter UI code and confirm both modes (custom range + last X days) are wired up
3. Review `loadSettings()` and confirm `filterEndDate` is reset to `Date()` on load
4. Review the options builder and confirm relative mode computes dates dynamically

## Completion
When implemented and building, output:
<promise>ISSUE 16 FIXED</promise>
