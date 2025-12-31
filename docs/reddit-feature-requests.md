# Reddit Feedback: Feature Requests + Feasibility

Source: comment thread pasted in chat (Apple Photos → Immich / ImmiBridge).

## Feature requests

### Quick wins (reasonable)
- ~~**Dry run / test mode**:~~ ✓ **Implemented** - Preview counts + what would upload; verify hash matching without uploading via "Dry Run" button in UI.
- ~~**Skip non-media sidecars**: Prevent attempts to upload files like `*_adjustments.plist` (avoid HTTP 400 errors).~~ ✓ **Implemented** (Dec 2025) - FileImmichSync now filters files by media type using UTType, skipping `.plist`, `.xmp`, `.aae`, and other non-media sidecars.
- **More filter options**: Expand filters beyond current ones (e.g., date ranges, favorites, shared/personal, etc.) as supported by PhotoKit.

### Medium effort (doable but larger)
- ~~**Older macOS support (e.g., 12.7.6)**: Potentially lower the deployment target if dependencies/UI APIs allow; requires build + runtime validation on older OS.~~ ✓ **Implemented** - Deployment target set to macOS 12.0 with docs and availability gates updated.
- ~~**x86_64 support**: Build for Intel Macs in addition to Apple Silicon.~~ ✓ **Implemented** - User `regularperson0001` confirmed x86_64 build works on Sonoma. Dual-architecture builds added to release script.
- **Export metadata mapping**: Write more metadata into exports (where feasible) and/or generate sidecar mapping files for albums/tags.
- ~~**Location/GPS data missing**: Photos uploaded to Immich are missing location metadata. User reported this works better than immich-go otherwise, but location is lost.~~ ✓ **Implemented** (Dec 2025) - Added full metadata sync feature:
  - Extracts location (latitude/longitude/altitude), favorites, hidden status from PHAsset
  - Uses Immich's PUT /api/assets/{id} endpoint to update metadata without re-uploading
  - Automatic metadata sync during regular backups + manual "Sync Metadata Only" button
  - Stores asset ID mappings for efficient change detection (only syncs when metadata differs)

### Large / risky / constrained
- **“Move” instead of “copy” (reduce iCloud usage)**: High risk of data loss; needs a guarded workflow (upload → server verify → delete) with strong confirmations and recovery plan.
- **Google Photos support**: Entire second ingestion pipeline (OAuth, paging, rate limits, metadata quirks). Feasible but non-trivial.
- **Album folders**: Likely constrained by Immich not supporting folder-of-albums; only workarounds (prefix naming/tag conventions).
- **Convert on export (e.g., JXL)**: Requires an encoder dependency, performance considerations, and careful metadata preservation.
- **Reverse sync (Immich → Apple Photos shared library/album)**: Generally complex/fragile due to Apple Photos write constraints and bidirectional sync conflicts.

## Noted concerns from the thread
- **Duplicates**: Users worry about duplicates if they later enable iPhone background upload; hash-based duplicate detection (matching Immich’s logic) mitigates this if implemented correctly.
