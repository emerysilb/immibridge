# Immich v2 / v3 compatibility tests

ImmiBridge talks to both Immich v2 and v3. The two APIs differ in ways that mostly
fail *loudly* — except one, which fails silently and destructively. This suite exists
to keep that from regressing.

```bash
./run.sh                    # default matrix: v2.5.6, v3.0.3, v3.1.0
./run.sh v3.2.0             # a newly released version
./run.sh v2.5.6 v3.2.0      # any set
```

Needs `docker`, `python3`, `swiftc`. Each version gets a throwaway stack on its own
port, and both harnesses are compiled against the **current** `Core/*.swift` — so
these test the shipping code, not a re-implementation of it.

## What the v3 API changed

| | v2 | v3 |
|---|---|---|
| `POST /assets/exist` | exists | **removed** |
| `deviceId` / `deviceAssetId` search filters | supported | **removed** |
| upload `duration` | seconds, fractional ok | **integer milliseconds** |
| archive | `isArchived: Bool` | `visibility: "archive" \| "timeline"` |

## The one that matters

v3's search DTO is a Zod object declared **without** `.strict()`. Zod's default is to
*strip* unknown keys, not reject them. So sending `deviceAssetId` to v3 does not
error — it returns `200` with the results of an **unfiltered** search, and `items[0]`
is an arbitrary asset from the library.

Callers use that id to delete an asset (mirror mode) or to write Photos metadata onto
it. Trusting it on v3 means silently clobbering an unrelated photo. There is no
exception to catch, which is why the client detects the server's major version up
front instead of probing and handling failure. Unknown version is treated as v3: the
v2-only endpoints are the dangerous ones, so "unsure" must never unlock them.

## Layout

- `compose.yml` — one parameterized stack (`IMMICH_TAG`, `IMMICH_PORT`). ML disabled;
  nothing here exercises it and it pulls gigabytes.
- `run.sh` — builds the harnesses, runs the matrix, asserts the wire log.
- `client_harness/` — drives the real `ImmichClient`: version probe, v2 gates, upload
  field construction, visibility round-trip, metadata targeting.
- `pipeline_harness/` — drives the real `ImmichUploadPipeline` **twice** over the same
  files with `checksumPrecheck` disabled. On v3 there is no `/assets/exist`, so the
  checksum path is the only duplicate gate left; if it breaks, every run re-uploads the
  whole library and re-downloads it from iCloud. `shim.swift` is concatenated onto a
  copy of `PhotoBackupCore.swift` at build time because `ImmichUploadPipeline` is
  file-private — checking in a copy of that file would rot on the first edit.
- `proxy.py` — recording HTTP proxy. Immich does not request-log by default, so sitting
  in the request path is the only trustworthy way to prove *which endpoints were
  actually called*. `run.sh` asserts v3 issues zero calls to the removed endpoints and
  that v2 still uses them.

## Adding a new Immich version

`./run.sh v3.2.0`. If it passes, add the tag to the default matrix in `run.sh`.
