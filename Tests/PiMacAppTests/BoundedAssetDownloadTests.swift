import Foundation
import Testing

@testable import PiMacApp

struct BoundedAssetDownloadTests {
  private final class AssetProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let url = request.url!
      let length = url.path == "/declared-large" ? "1000" : "4"
      var headers = ["Content-Type": "image/png"]
      if url.path != "/unknown-length" { headers["Content-Length"] = length }
      let response = HTTPURLResponse(
        url: url, statusCode: url.path == "/missing" ? 404 : 200,
        httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data([1, 2, 3, 4]))
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  @Test func validAssetHonorsExactLimit() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AssetProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let bytes = try await BoundedAssetDownload.data(
      from: URL(string: "https://asset.test/valid")!, session: session,
      limit: 4, mimeType: "image/png")
    #expect(bytes == Data([1, 2, 3, 4]))
  }

  @Test(arguments: ["/declared-large", "/unknown-length", "/valid", "/missing"])
  func excessiveOrFailedAssetsNeverBecomeValidData(path: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AssetProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await BoundedAssetDownload.data(
        from: URL(string: "https://asset.test\(path)")!, session: session,
        limit: 3, mimeType: "image/png")
      Issue.record("超限或失败的资源不能成为有效数据")
    } catch let error as BoundedAssetDownload.Failure {
      switch error {
      case .invalidResponse: #expect(path == "/missing")
      case .tooLarge: #expect(path != "/missing")
      }
    }
  }

  @Test func mimeMismatchIsAnErrorNotEmptyContent() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AssetProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await BoundedAssetDownload.data(
        from: URL(string: "https://asset.test/valid")!, session: session,
        limit: 4, mimeType: "text/html")
      Issue.record("错误的资源类型必须失败")
    } catch let error as BoundedAssetDownload.Failure {
      if case .invalidResponse = error {} else { Issue.record("应报告响应类型错误") }
    }
  }
}
