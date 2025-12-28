# Reddit Feedback: Feature Requests + Feasibility

Source: comment thread pasted in chat (Apple Photos → Immich / ImmiBridge).

## Feature requests

### Quick wins (reasonable)
- **Dry run / test mode**: Preview counts + what would upload; verify hash matching without uploading.
- **Skip non-media sidecars**: Prevent attempts to upload files like `*_adjustments.plist` (avoid HTTP 400 errors).
- **More filter options**: Expand filters beyond current ones (e.g., date ranges, favorites, shared/personal, etc.) as supported by PhotoKit.

### Medium effort (doable but larger)
- **Older macOS support (e.g., 12.7.6)**: Potentially lower the deployment target if dependencies/UI APIs allow; requires build + runtime validation on older OS.
- **Export metadata mapping**: Write more metadata into exports (where feasible) and/or generate sidecar mapping files for albums/tags.

### Large / risky / constrained
- **“Move” instead of “copy” (reduce iCloud usage)**: High risk of data loss; needs a guarded workflow (upload → server verify → delete) with strong confirmations and recovery plan.
- **Google Photos support**: Entire second ingestion pipeline (OAuth, paging, rate limits, metadata quirks). Feasible but non-trivial.
- **Album folders**: Likely constrained by Immich not supporting folder-of-albums; only workarounds (prefix naming/tag conventions).
- **Convert on export (e.g., JXL)**: Requires an encoder dependency, performance considerations, and careful metadata preservation.
- **Reverse sync (Immich → Apple Photos shared library/album)**: Generally complex/fragile due to Apple Photos write constraints and bidirectional sync conflicts.

## Noted concerns from the thread
- **Duplicates**: Users worry about duplicates if they later enable iPhone background upload; hash-based duplicate detection (matching Immich’s logic) mitigates this if implemented correctly.

