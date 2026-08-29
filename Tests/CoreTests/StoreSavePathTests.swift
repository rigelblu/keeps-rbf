// #keeps-15: a RESOLVED snapshot (frames shifted into today's coordinates, `displays` still carrying the SAVED
// bounds) must never be written back — a second load would shift its frames twice. The guard is a convention
// (grill Q5: a wrapper type would change every downstream signature): the only things ever saved are fresh
// `Capture.capture()` results. This test makes the convention checkable by reading the sources: every
// `Store().save(` call site is one of the two capture paths in `main.swift`, and nothing saves inside `Core`.
import Foundation
import Testing

@testable import Core

@Suite struct StoreSavePathTests {
  private var sourcesRoot: URL {
    // Tests/CoreTests/StoreSavePathTests.swift → <repo>/Sources
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
  }

  private func swiftFiles(under root: URL) throws -> [URL] {
    let e = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  @Test func theOnlySaveCallersAreTheTwoCapturePathsInMain() throws {
    var hits: [(file: String, line: String)] = []
    for url in try swiftFiles(under: sourcesRoot) {
      let text = try String(contentsOf: url, encoding: .utf8)
      for line in text.split(separator: "\n") where line.contains(".save(") && !line.contains("func save(") {
        hits.append((url.lastPathComponent, line.trimmingCharacters(in: .whitespaces)))
      }
    }
    #expect(hits.count == 2, "expected exactly the two capture-path saves, found: \(hits)")
    #expect(hits.allSatisfy { $0.file == "main.swift" }, "no save site outside the host: \(hits)")
    // Both sites save what `Capture.capture()` / `Capture.snapshot()` just produced — never a loaded snapshot.
    #expect(
      hits.contains { $0.line.contains("Store().save(result.snapshot)") },
      "captureAndStore saves the fresh capture result")
    #expect(hits.contains { $0.line.contains("Store().save(snap)") }, "--capture-once saves the fresh capture")
  }

  @Test func nothingInCoreSavesASnapshot() throws {
    for url in try swiftFiles(under: sourcesRoot.appendingPathComponent("Core")) where url.lastPathComponent != "Store.swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(!text.contains(".save("), "\(url.lastPathComponent) must not save — a resolved snapshot lives in Core")
    }
  }
}
