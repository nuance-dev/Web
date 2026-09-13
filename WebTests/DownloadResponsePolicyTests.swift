import Foundation
import Testing
@testable import Web

struct DownloadResponsePolicyTests {
    private func response(mimeType: String, disposition: String? = nil) -> HTTPURLResponse {
        var headers = ["Content-Type": mimeType]
        if let disposition { headers["content-disposition"] = disposition }
        return HTTPURLResponse(url: URL(string: "https://example.com/file")!,
                               statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func textAttachmentsDownloadEvenWhenWebKitCanDisplayThem() {
        let attachment = response(mimeType: "text/plain",
                                  disposition: "attachment; filename=\"notes.txt\"")
        #expect(DownloadResponsePolicy.shouldDownload(attachment, canShowMIMEType: true))
    }

    @Test func attachmentTypeIgnoresHeaderCasingAndSurroundingWhitespace() {
        for disposition in ["ATTACHMENT", " Attachment ; filename*=UTF-8''notes.txt", "\tattachment\t; filename=notes.txt"] {
            #expect(DownloadResponsePolicy.shouldDownload(
                response(mimeType: "text/html", disposition: disposition), canShowMIMEType: true))
        }
    }

    @Test func displayableDocumentsAndMediaStayInTheBrowser() {
        for mimeType in ["text/html", "text/plain", "application/pdf", "image/png", "video/mp4"] {
            #expect(!DownloadResponsePolicy.shouldDownload(response(mimeType: mimeType), canShowMIMEType: true))
            #expect(!DownloadResponsePolicy.shouldDownload(
                response(mimeType: mimeType, disposition: "inline; filename=\"attachment.txt\""),
                canShowMIMEType: true))
        }
    }

    @Test func unsupportedContentDownloadsWithoutAnAttachmentHeader() {
        #expect(DownloadResponsePolicy.shouldDownload(response(mimeType: "application/octet-stream"),
                                                       canShowMIMEType: false))
        #expect(DownloadResponsePolicy.shouldDownload(
            response(mimeType: "application/x-custom", disposition: "inline"), canShowMIMEType: false))
    }
}
