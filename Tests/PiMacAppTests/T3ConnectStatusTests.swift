import Foundation
import Testing

@testable import PiMacApp

struct T3ConnectStatusTests {
  private func status(_ tunnel: String?) throws -> T3ConnectStatus {
    var value: [String: Any] = [
      "available": true, "enabled": true, "linked": true,
      "loginPending": false, "busy": false, "account": "fixture", "message": "",
      "requests": 0, "accepted": 0, "queuedDeliveries": 0,
      "successfulDeliveries": 0, "failedDeliveries": 0,
    ]
    if let tunnel { value["tunnelStatus"] = tunnel }
    return try JSONDecoder().decode(
      T3ConnectStatus.self, from: JSONSerialization.data(withJSONObject: value))
  }

  @Test func connectorLivenessIsNotPresentedAsReadiness() throws {
    #expect(try status("running").tunnelDescription.contains("尚未确认"))
    #expect(try status("connecting").tunnelDescription.contains("正在连接"))
    #expect(try status("connected").tunnelDescription.contains("已连接 Cloudflare"))
    #expect(try status("reconnecting").tunnelDescription.contains("自动恢复"))
    #expect(try status("failed:spawn-failed").tunnelDescription.contains("启动失败"))
    #expect(try status("disabled").tunnelDescription.contains("等待恢复"))
    #expect(try status(nil).tunnelDescription.contains("正在确认"))
    #expect(try status("future-state").tunnelDescription.contains("正在确认"))
  }
}
