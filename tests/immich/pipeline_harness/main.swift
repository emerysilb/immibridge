// Second-run duplicate detection at the PIPELINE level (not just the raw client call).
//
// On v3 there is no /assets/exist, so the only thing between a second run and a full library
// re-upload (plus a full iCloud re-download) is the checksum bulk-upload-check path. This
// drives the REAL ImmichUploadPipeline twice over the same files and asserts the second pass
// uploads nothing and still records the mappings.
//
//   usage: duptest <baseURL> <apiKey> <expectedMajor>

import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let base = URL(string: args[1]) else { exit(2) }
let apiKey = args[2]
let expectedMajor = Int(args[3])!

var failures = 0
func check(_ name: String, _ passed: Bool, _ detail: String) {
    print("  [\(passed ? "PASS" : "FAIL")] \(name)\n         \(detail)")
    if !passed { failures += 1 }
}

func makeJPEG(tag: String) -> Data {
    let b64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q=="
    var d = Data(base64Encoded: b64)!
    d.append(contentsOf: [0xFF, 0xFE])
    d.append(tag.data(using: .utf8)!)
    return d
}

let client = ImmichClient(serverURL: base, apiKey: apiKey)

func serverTotal() -> Int {
    var req = URLRequest(url: base.appendingPathComponent("api/assets/statistics"))
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    let sem = DispatchSemaphore(value: 0)
    var total = -1
    URLSession.shared.dataTask(with: req) { d, _, _ in
        if let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            total = (j["total"] as? Int) ?? -1
        }
        sem.signal()
    }.resume()
    sem.wait()
    return total
}

// Unique per run so we never collide with the live sync happening on the same server.
let runTag = String(UUID().uuidString.prefix(8))
var files: [(url: URL, deviceAssetId: String)] = []
for i in 0..<3 {
    let tag = "\(runTag)-\(i)"
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(tag).jpg")
    try! makeJPEG(tag: tag).write(to: u)
    files.append((u, "duptest-\(tag)"))
}

// checksumPrecheck deliberately OFF. A user who turned it off must STILL get dedup on v3 —
// this is exactly the config that would otherwise re-upload the entire library every run.
func makeOptions() -> ImmichUploadOptions {
    ImmichUploadOptions(
        serverURL: base, apiKey: apiKey, deviceId: "immibridge-duptest",
        checksumPrecheck: false,
        uploadConcurrency: 2, hashConcurrency: 2, maxInFlight: 4,
        syncAlbums: false, updateChangedAssets: false
    )
}

print("\n=== PASS 1 (fresh upload) ===")
let before1 = serverTotal()
let p1 = __dupTestPass(label: "run1", options: makeOptions(), client: client, files: files)
let after1 = serverTotal()
check("pass 1 uploaded all 3 files", after1 - before1 == 3,
      "server total \(before1) -> \(after1) (delta \(after1 - before1)); dupSkips=\(p1.dupSkips)")
check("pass 1 recorded 3 mappings", p1.persisted.count == 3,
      "persisted=\(p1.persisted.count)")

print("\n=== PASS 2 (same files again — must NOT re-upload) ===")
let before2 = serverTotal()
let p2 = __dupTestPass(label: "run2", options: makeOptions(), client: client, files: files)
let after2 = serverTotal()
check("pass 2 uploaded NOTHING", after2 - before2 == 0,
      "server total \(before2) -> \(after2) (delta \(after2 - before2)) — any increase is a full re-upload every run")
// v3 only: with no /assets/exist, the client-side checksum gate must fire and skip before
// sending bytes. v2 keeps its original routing (exist-skip / server-side duplicate reject),
// so it legitimately reaches the server — it just never creates a new asset.
if expectedMajor >= 3 {
    check("pass 2 skipped client-side before uploading bytes", p2.dupSkips == 3,
          "dupSkips=\(p2.dupSkips) (checksumPrecheck was OFF; on v3 it must be forced on)")
} else {
    print("  [SKIP] client-side skip assertion is v3-only; v2 routing deliberately unchanged")
}
check("pass 2 still recorded 3 mappings", p2.persisted.count == 3,
      "persisted=\(p2.persisted.count) — a skipped duplicate must still map deviceAssetId -> assetId")
check("pass 2 mapped to the SAME asset ids as pass 1",
      !p1.persisted.isEmpty && p1.persisted == p2.persisted,
      "run1=\(p1.persisted.sorted { $0.key < $1.key }.map { String($0.value.prefix(8)) }) run2=\(p2.persisted.sorted { $0.key < $1.key }.map { String($0.value.prefix(8)) })")

for f in files { try? FileManager.default.removeItem(at: f.url) }
print("\n=== duptest (major \(expectedMajor)) done: \(failures) failure(s) ===")
exit(failures == 0 ? 0 : 1)
