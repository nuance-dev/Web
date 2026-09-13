import Foundation
import Testing
@testable import Web

@MainActor
struct FileSecurityValidatorTests {
    @Test func textAttachmentUsesSuggestedFilenameForExtensionlessEndpoint() async {
        let validator = FileSecurityValidator(loadPersistedSettings: false)
        let result = await validator.analyzeFileSecurity(
            url: URL(string: "https://example.test/file")!,
            suggestedFilename: "web-browser-smoke-check.txt", mimeType: "text/plain",
            expectedFileSize: 32)
        #expect(result.fileExtension == "txt")
        #expect(result.riskLevel == .safe)
        #expect(!result.requiresUserConfirmation)
        #expect(!result.isSpoofed)
    }

    @Test func textFilenameDisguiseDoesNotAllowExecutable() async {
        let validator = FileSecurityValidator(loadPersistedSettings: false)
        let result = await validator.analyzeFileSecurity(
            url: URL(string: "https://example.test/file")!,
            suggestedFilename: "report.txt.exe", mimeType: "text/plain", expectedFileSize: 32)
        #expect(result.riskLevel == .critical)
        #expect(result.isExecutable)
        #expect(result.isSpoofed)
        #expect(validator.shouldBlockDownload(result))
    }

    @Test func knownTextExtensionDoesNotSuppressDangerousMIMEOrUnknownTypeChecks() async {
        let validator = FileSecurityValidator(loadPersistedSettings: false)
        let executableMIME = await validator.analyzeFileSecurity(
            url: URL(string: "https://example.test/file")!,
            suggestedFilename: "report.txt", mimeType: "application/x-executable", expectedFileSize: 32)
        #expect(executableMIME.riskLevel >= .high)
        #expect(executableMIME.requiresUserConfirmation)

        let unknown = await validator.analyzeFileSecurity(
            url: URL(string: "https://example.test/file")!,
            suggestedFilename: "download.unrecognized", mimeType: "application/octet-stream",
            expectedFileSize: 32)
        #expect(unknown.riskLevel >= .medium)
        #expect(unknown.requiresUserConfirmation)
    }
}
