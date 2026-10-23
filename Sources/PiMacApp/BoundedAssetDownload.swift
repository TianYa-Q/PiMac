import Foundation

/// 非隔离 async 函数运行于通用执行器，逐字节消费不能继承桌面 MainActor。
enum BoundedAssetDownload {
  enum Failure: Error { case invalidResponse, tooLarge }

  static func data(
    from url: URL, session: URLSession, limit: Int, mimeType: String?
  ) async throws -> Data {
    let (bytes, response) = try await session.bytes(from: url)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      mimeType == nil || response.mimeType?.lowercased() == mimeType
    else { throw Failure.invalidResponse }
    guard response.expectedContentLength <= limit else { throw Failure.tooLarge }
    var data = Data()
    // 不能改成无上限的 data(from:)：未知/虚报 Content-Length 也必须受内存上限约束。
    for try await byte in bytes {
      guard data.count < limit else { throw Failure.tooLarge }
      data.append(byte)
    }
    try Task.checkCancellation()
    return data
  }
}
