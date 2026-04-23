# Issue #21: Fix Deprecated Immich API Endpoint

## Goal
Fix `getAssetIdByDeviceId` which uses removed Immich API endpoints (`/api/assets/device/...` and `/api/assets/assetByDeviceId/...`), causing 404 errors on Immich 2.5.6+ and breaking the entire metadata sync phase.

## Problem
The function `getAssetIdByDeviceId` at line 2553 of `PhotoBackupCore.swift` tries two deprecated GET endpoints that no longer exist in the Immich API. Both return 404. The function silently returns `nil`, which causes:

1. **Metadata sync (line 1811)**: Every asset without a stored `AssetMappingStore` entry fails lookup, gets counted as "notInImmich", and metadata sync is entirely skipped. This is the critical breakage.
2. **Update-changed uploads (line 3232)**: Can't find existing asset to delete before re-upload, causing duplicates.
3. **File sync (FileImmichSync.swift line 179)**: Same as #2.

## Files to Modify
- `ImmiBridge/ImmiBridge/Core/PhotoBackupCore.swift` -- primary fix in `getAssetIdByDeviceId` (line 2553)
- `ImmiBridge/ImmiBridge/Core/FileImmichSync.swift` -- may need matching fix if it has its own lookup

## Available Working Endpoints

The app already uses these Immich endpoints that STILL WORK:
- `POST /api/assets/bulk-upload-check` (line 2523) -- checks if assets exist by checksum, returns `assetId` for existing ones
- `POST /api/assets/exist` -- checks existence by device asset IDs

The modern Immich API also supports:
- `POST /api/search/metadata` -- search by various fields including `deviceAssetId` and `deviceId`

## Fix Approach

Replace the body of `getAssetIdByDeviceId` (lines 2553-2574) to use the Immich search API:

```swift
func getAssetIdByDeviceId(deviceId: String, deviceAssetId: String) async throws -> String? {
    // Use the search/metadata endpoint which supports deviceAssetId lookup
    let searchBody: [String: Any] = [
        "deviceAssetId": deviceAssetId,
        "deviceId": deviceId
    ]
    let body = try JSONSerialization.data(withJSONObject: searchBody, options: [])

    do {
        let data = try await requestRaw(method: "POST", path: "search/metadata", body: body)
        // Response is { "assets": { "items": [...], "total": N, ... } }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = obj["assets"] as? [String: Any],
           let items = assets["items"] as? [[String: Any]],
           let first = items.first,
           let id = first["id"] as? String {
            return id
        }
    } catch {
        // Log but don't throw -- callers handle nil gracefully
        print("getAssetIdByDeviceId search failed: \(error)")
    }

    return nil
}
```

**Alternative:** If the search/metadata endpoint doesn't work or has a different response shape, try using `POST /api/assets/bulk-upload-check` with the device asset ID (this requires a checksum though, which may not be available at all call sites).

**Important:** Research the actual Immich API response format. The search endpoint may return results differently in newer versions. Check the Immich API docs at `https://immich.app/docs/api/` or test against the existing `requestJSON` helper to decode properly.

## Call Sites (do NOT modify these)
The three call sites already handle `nil` returns gracefully:
- Line 1811: metadata sync -- skips asset (already the current behavior)
- Line 3232: update-changed -- logs error, continues upload
- `FileImmichSync.swift` line 179: skips replacement

These do NOT need changes -- just fixing the function itself will unblock them.

## Constraints
- Do NOT change the function signature -- callers depend on `(deviceId: String, deviceAssetId: String) async throws -> String?`
- Do NOT remove the function -- 3 call sites depend on it
- Do NOT modify `bulkUploadCheck` or `checkExistingAssets` -- they work fine
- Keep graceful error handling (return nil on failure, don't crash)
- The fix must work with Immich 2.5.6+ (current stable)

## Verification
1. Build succeeds: `xcodebuild -project ImmiBridge/ImmiBridge.xcodeproj -scheme ImmiBridge -configuration Debug build`
2. Read the updated `getAssetIdByDeviceId` and confirm it uses a valid modern endpoint
3. Confirm the function still returns `String?` and handles errors gracefully
4. Verify no other deprecated endpoints exist -- search for `assets/device/` and `assetByDeviceId` in the codebase

## Completion
When implemented and building, output:
<promise>ISSUE 21 FIXED</promise>
