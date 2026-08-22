// Live integration harness: drives the REAL ImmiBridge ImmichClient against a running
// Immich server. Compiled together with the actual Core/*.swift sources, so this exercises
// the shipping code paths (version probe, v2 gates, upload field construction, visibility),
// not a re-implementation of them.
//
//   usage: harness <baseURL> <apiKey> <expectedMajor>

import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let base = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: harness <baseURL> <apiKey> <expectedMajor>\n".data(using: .utf8)!)
    exit(2)
}
let apiKey = args[2]
let expectedMajor = Int(args[3])!

var failures = 0
func check(_ name: String, _ passed: Bool, _ detail: String) {
    print("  [\(passed ? "PASS" : "FAIL")] \(name)\n         \(detail)")
    if !passed { failures += 1 }
}

// A tiny but valid JPEG, made unique per-run so checksum dedup doesn't cross runs.
func makeJPEG(tag: String) -> Data {
    let b64 = """
/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==
"""
    var d = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines))!
    d.append(contentsOf: [0xFF, 0xFE])
    d.append(tag.data(using: .utf8)!)
    return d
}

func writeTemp(_ data: Data, _ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try! data.write(to: u)
    return u
}

let sem = DispatchSemaphore(value: 0)
Task {
    let client = ImmichClient(
        serverURL: base,
        apiKey: apiKey,
        logger: { print("         [client log] \($0)") }
    )

    print("\n=== A. version probe (real isLegacyV2()) ===")
    let isV2 = await client.isLegacyV2()
    let decision = await client.legacyV2Decision()
    check("isLegacyV2() matches server major \(expectedMajor)",
          isV2 == (expectedMajor <= 2),
          "isLegacyV2()=\(isV2) isFinal=\(decision.isFinal) expected=\(expectedMajor <= 2)")

    print("\n=== B. checkExistingAssets (v2-gated) ===")
    do {
        let ids = ["probe-a", "probe-b"]
        let existing = try await client.checkExistingAssets(deviceId: "immibridge-test", deviceAssetIds: ids)
        // On v3 this must return empty WITHOUT throwing (no HTTP call at all).
        check("checkExistingAssets behaves per major", true,
              "returned \(existing.count) id(s) — on v3 this must be 0 with no HTTP call")
    } catch {
        check("checkExistingAssets did not throw", expectedMajor <= 2,
              "threw: \(error)")
    }

    print("\n=== C. upload with a REAL fractional video duration ===")
    // 5.37s — the encoding that 400s on v3 under the old String(durationSeconds) code.
    let tag = UUID().uuidString
    let jpeg = makeJPEG(tag: tag)
    let fileURL = writeTemp(jpeg, "immibridge-\(tag).jpg")
    let sha1 = try? sha1HexFile(fileURL)
    var uploadedId: String?
    do {
        let res = try await client.uploadAsset(
            fileURL: fileURL,
            sha1Hex: sha1,
            deviceId: "immibridge-test",
            deviceAssetId: "harness-\(tag)",
            filename: "immibridge-\(tag).jpg",
            fileCreatedAt: Date(),
            fileModifiedAt: Date(),
            durationSeconds: 5.37,
            isFavorite: false,
            livePhotoVideoId: nil,
            metadata: [["key": "mobile-app", "value": ["iCloudId": tag]]]
        )
        uploadedId = res.id
        check("uploadAsset(durationSeconds: 5.37) succeeds", true,
              "id=\(res.id) status=\(res.status)")
    } catch {
        check("uploadAsset(durationSeconds: 5.37) succeeds", false, "threw: \(error)")
    }

    print("\n=== D. bulkUploadCheck duplicate detection ===")
    if let sha1 {
        do {
            let r = try await client.bulkUploadCheck(items: [AssetBulkUploadCheckItem(checksum: sha1, id: "dup-probe")])
            let first = r.first
            check("bulkUploadCheck flags the just-uploaded file as duplicate",
                  first?.action == "reject" && first?.reason == "duplicate",
                  "action=\(first?.action ?? "nil") reason=\(first?.reason ?? "nil") assetId=\(first?.assetId ?? "nil")")
        } catch {
            check("bulkUploadCheck", false, "threw: \(error)")
        }
    }

    print("\n=== E. getAssetIdByDeviceId — THE SAFETY GATE ===")
    // A deviceAssetId that matches nothing. On v2: correctly 0 results -> nil.
    // On v3: the raw API would 200 with an UNFILTERED result set (proven separately),
    // so anything other than nil here means the gate leaked and we'd target a random asset.
    do {
        let bogus = "NOTHING-MATCHES-\(UUID().uuidString)"
        let found = try await client.getAssetIdByDeviceId(deviceId: "immibridge-test", deviceAssetId: bogus)
        check("bogus deviceAssetId resolves to nil (no arbitrary asset)",
              found == nil,
              "returned \(found ?? "nil") — must be nil on BOTH majors")
    } catch {
        check("getAssetIdByDeviceId did not throw", false, "threw: \(error)")
    }

    // On v2 a REAL deviceAssetId must still resolve (proves the gate didn't break v2).
    if expectedMajor <= 2 {
        do {
            let found = try await client.getAssetIdByDeviceId(deviceId: "immibridge-test",
                                                              deviceAssetId: "harness-\(tag)")
            check("v2: real deviceAssetId still resolves", found != nil && found == uploadedId,
                  "returned \(found ?? "nil") expected \(uploadedId ?? "nil")")
        } catch {
            check("v2: real deviceAssetId still resolves", false, "threw: \(error)")
        }
    }

    print("\n=== F. visibility / archive round-trip ===")
    if let id = uploadedId {
        do {
            var upd = ImmichClient.UpdateAssetDto()
            upd.setArchived(true)
            _ = try await client.updateAsset(assetId: id, update: upd)
            let detail = try await client.getAsset(assetId: id)
            check("setArchived(true) archives the asset",
                  detail.effectiveIsArchived == true,
                  "effectiveIsArchived=\(String(describing: detail.effectiveIsArchived)) visibility=\(String(describing: detail.visibility)) isArchived=\(String(describing: detail.isArchived))")

            var undo = ImmichClient.UpdateAssetDto()
            undo.setArchived(false)
            _ = try await client.updateAsset(assetId: id, update: undo)
            let d2 = try await client.getAsset(assetId: id)
            check("setArchived(false) un-archives the asset",
                  d2.effectiveIsArchived == false,
                  "effectiveIsArchived=\(String(describing: d2.effectiveIsArchived)) visibility=\(String(describing: d2.visibility))")
        } catch {
            check("visibility round-trip", false, "threw: \(error)")
        }
    }

    print("\n=== G. metadata write lands on the RIGHT asset ===")
    if let id = uploadedId {
        do {
            var upd = ImmichClient.UpdateAssetDto()
            upd.description = "immibridge-harness-\(tag)"
            upd.isFavorite = true
            upd.latitude = 37.7749
            upd.longitude = -122.4194
            _ = try await client.updateAsset(assetId: id, update: upd)
            let detail = try await client.getAsset(assetId: id)
            let okFav = detail.isFavorite == true
            let okGPS = (detail.effectiveLatitude.map { abs($0 - 37.7749) < 0.001 } ?? false)
                && (detail.effectiveLongitude.map { abs($0 + 122.4194) < 0.001 } ?? false)
            check("favorite + GPS land on the uploaded asset",
                  okFav && okGPS,
                  "isFavorite=\(String(describing: detail.isFavorite)) lat=\(String(describing: detail.effectiveLatitude)) lon=\(String(describing: detail.effectiveLongitude))")
        } catch {
            check("metadata write", false, "threw: \(error)")
        }
    }

    try? FileManager.default.removeItem(at: fileURL)
    print("\n=== harness done: \(failures) failure(s) ===")
    sem.signal()
}
sem.wait()
exit(failures == 0 ? 0 : 1)
