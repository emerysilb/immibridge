# Issue #22: Edited Mode Should Backup Videos

## Goal
Make "Edited" backup mode include videos, not just images. Currently, three places in `PhotoBackupCore.swift` guard edited-mode logic with `if asset.mediaType == .image`, causing all videos to be silently skipped.

## Problem
In Edited mode (and Both mode), videos are completely ignored because the code only processes images. The fix should export videos using the existing video export path (via `exportResourceToOutputs`), which already handles `.fullSizeVideo` resources. For videos, the "edited" version in PhotoKit is simply the `fullSizeVideo` resource (which contains edits like trims), falling back to the `video` resource if no edits exist.

## File to Modify
- `ImmiBridge/ImmiBridge/Core/PhotoBackupCore.swift` -- this is the ONLY file that needs changes

## Three Locations to Fix

### Location 1: Dry-run Immich exist-check IDs (lines 1086-1090)
Current code:
```swift
if options.mode == .edited || options.mode == .both {
    if asset.mediaType == .image {
        ids.append(asset.localIdentifier + ":edited")
    }
}
```

Fix: Also handle videos:
```swift
if options.mode == .edited || options.mode == .both {
    if asset.mediaType == .image {
        ids.append(asset.localIdentifier + ":edited")
    } else if asset.mediaType == .video {
        ids.append(asset.localIdentifier + ":edited")
    }
}
```
(Or simply remove the `if asset.mediaType == .image` guard and use `if asset.mediaType == .image || asset.mediaType == .video`)

### Location 2: Main Immich exist-check IDs (lines 1262-1266)
Same pattern as Location 1. Add video support.

### Location 3: Main export logic (lines 1577-1663)
This is the biggest change. After the existing `if asset.mediaType == .image { ... }` block (which calls `exportEditedImageToOutputs`), add an `else if asset.mediaType == .video { ... }` block that:

1. Sets `assetHadAnyWork = true`
2. Computes the manifest key using variant `"edited"`
3. Gets the video resource: prefer `fullSizeVideo` (contains edits), fall back to `video`
4. Checks manifest for skip (same pattern as originals video export at lines 1538-1573)
5. Calls `exportResourceToOutputs()` with the video resource (same function used for originals video export)
6. Uses deviceAssetIdSuffix `":edited"` to differentiate from the originals upload

**Reference the existing video export block at lines 1538-1574** for the exact pattern. The edited-video block should mirror that structure but use `fullSizeVideo ?? video` as the resource and `":edited"` as the variant/suffix.

The resources are already enumerated earlier in the function. Look for where `fullSizeVideo` and `video` are extracted from `PHAssetResource.assetResources(for: asset)` -- they should already be available as local variables.

## Constraints
- Do NOT modify `exportEditedImageToOutputs` -- it's image-specific and correct as-is
- Do NOT change how image editing export works
- Do NOT add new helper functions unless absolutely necessary
- Reuse the existing `exportResourceToOutputs` function for video export
- Keep the same manifest/incremental tracking pattern
- Keep the same error handling pattern (catch NSError code 499 for user stop)

## Verification
1. Build succeeds: `xcodebuild -project ImmiBridge/ImmiBridge.xcodeproj -scheme ImmiBridge -configuration Debug build`
2. Search for `asset.mediaType == .image` in the edited mode blocks -- there should now be corresponding `.video` handling
3. Verify the exist-check IDs at all three locations handle both image and video
4. Confirm the video export in edited mode uses `exportResourceToOutputs` (not `exportEditedImageToOutputs`)

## Completion
When implemented and building, output:
<promise>ISSUE 22 FIXED</promise>
