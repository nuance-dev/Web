import Foundation
import Testing
@testable import Web

struct DownloadFileLifecycleTests {
    @Test func stagingCreatesPrivateDirectoryWithoutPrecreatingWebKitDestination() throws {
        let staged = try StagedDownloadFile(filename: "../../report.txt")
        let directory = staged.url.deletingLastPathComponent()
        #expect(staged.url.lastPathComponent == "report.txt")
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func abandonedStagingRemovesPartialBytes() throws {
        var staged: StagedDownloadFile? = try StagedDownloadFile(filename: "partial.txt")
        let url = try #require(staged?.url)
        try Data("partial transfer".utf8).write(to: url)
        staged = nil
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func takingTemporaryFileOwnsBytesBeforeCallbackReturns() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let content = Data("download body".utf8)
        try content.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try StagedDownloadFile(taking: source)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: staged.url) == content)
    }

    @Test func completedMoveSurvivesStagingCleanup() throws {
        var staged: StagedDownloadFile? = try StagedDownloadFile(filename: "report.txt")
        let source = try #require(staged?.url)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("finished".utf8).write(to: source)
        try FileManager.default.moveItem(at: source, to: destination)
        staged = nil
        #expect(try String(contentsOf: destination, encoding: .utf8) == "finished")
        #expect(!FileManager.default.fileExists(atPath: source.deletingLastPathComponent().path))
    }

    @Test func destinationAvoidsExistingFilesAndConcurrentReservations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("report.txt")
        try Data("existing".utf8).write(to: target)
        let reserved = directory.appendingPathComponent("report (1).txt")
        let result = DownloadFileDestination.uniqueURL(for: target, reservedURLs: [reserved])
        #expect(result.lastPathComponent == "report (2).txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    @Test func extensionlessCollisionDoesNotAddTrailingDot() {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = DownloadFileDestination.uniqueURL(for: target, reservedURLs: [target])
        #expect(result.lastPathComponent == target.lastPathComponent + " (1)")
        #expect(result.pathExtension.isEmpty)
    }

    @Test func quarantineRoundTripsNativeProtectionAgentAndDate() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test download".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = URL(string: "https://example.test/file.txt")!
        let referrer = URL(string: "https://example.test/downloads")!
        #expect(try QuarantineFileMetadata.apply(to: file, sourceURL: source, referrerURL: referrer, isPrivate: false))
        let metadata = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        // Launch Services may omit these optional URLs from its readback, even
        // when called directly with CFURL values. Verify any values it returns.
        if let storedSource = metadata?["LSQuarantineDataURL"] {
            #expect(storedSource as? URL == source)
        }
        if let storedReferrer = metadata?["LSQuarantineOriginURL"] {
            #expect(storedReferrer as? URL == referrer)
        }
        #expect(metadata?["LSQuarantineAgentName"] as? String == "Web Browser")
        #expect(metadata?["LSQuarantineTimeStamp"] as? Date != nil)
        let data = try extendedAttribute("com.apple.quarantine", from: file)
        let record = try #require(String(data: data, encoding: .utf8))
        let fields = record.split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count >= 3)
        let flags = try #require(fields.first.flatMap { UInt16($0, radix: 16) })
        #expect(flags != 0)
        #expect(!data.starts(with: Data("bplist".utf8)))
    }

    @Test func privateQuarantineClearsPreexistingOriginAndSpotlightMetadata() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("private download".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = URL(string: "https://example.test/private-file?token=synthetic")!
        let referrer = URL(string: "https://example.test/private-page")!
        #expect(try QuarantineFileMetadata.apply(to: file, sourceURL: source, referrerURL: referrer, isPrivate: false))
        let whereFroms = try PropertyListSerialization.data(fromPropertyList: [source.absoluteString], format: .binary, options: 0)
        let wroteMetadata = whereFroms.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, whereFroms.count, 0, 0)
        }
        #expect(wroteMetadata == 0)
        #expect(try QuarantineFileMetadata.apply(to: file, sourceURL: source, referrerURL: referrer, isPrivate: true))
        let freshFile = URL(fileURLWithPath: file.path)
        let metadata = try freshFile.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(metadata?.isEmpty == false)
        #expect(metadata?["LSQuarantineDataURL"] == nil)
        #expect(metadata?["LSQuarantineOriginURL"] == nil)
        #expect(metadata?["LSQuarantineTimeStamp"] as? Date != nil)
        #expect(metadata?["LSQuarantineAgentName"] as? String != nil)
        #expect(getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0) == -1)
        #expect(errno == ENOATTR)
        let record = try #require(String(data: extendedAttribute("com.apple.quarantine", from: file), encoding: .utf8))
        #expect(record.split(separator: ";").count >= 3)
    }

    private func extendedAttribute(_ name: String, from file: URL) throws -> Data {
        let length = getxattr(file.path, name, nil, 0, 0, 0)
        guard length >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, length, 0, 0) }
        guard count == length else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data
    }
}
