import Foundation
import Testing

@testable import PiMacApp

struct ModelContextLimitTests {
  @Test func emptyRestoresDefaultAndPositiveIntegersAreNormalized() throws {
    #expect(try ModelContextLimit.parse("") == nil)
    #expect(try ModelContextLimit.parse(" \n ") == nil)
    #expect(try ModelContextLimit.parse(" 1050000 ") == 1_050_000)
    #expect(try ModelContextLimit.parse("000272000") == 272_000)
    #expect(
      try ModelContextLimit.parse(String(ModelContextLimit.maximumTokens))
        == ModelContextLimit.maximumTokens)
  }

  @Test func programmaticLimitsUseTheSameBoundary() throws {
    try ModelContextLimit.validate(nil)
    try ModelContextLimit.validate(1)
    try ModelContextLimit.validate(ModelContextLimit.maximumTokens)
    for tokens in [Int.min, -1, 0, ModelContextLimit.maximumTokens + 1, Int.max] {
      #expect(throws: ModelContextLimit.ValidationError.self) {
        try ModelContextLimit.validate(tokens)
      }
    }
  }

  @Test func defaultsAndOverridesRemainSeparateInTheSnapshot() throws {
    let data = Data(
      #"{"overrides":{"test/model":1050000},"defaults":{"test/model":272000}}"#.utf8)
    let settings = try JSONDecoder().decode(ModelContextSettings.self, from: data)
    #expect(settings.overrides["test/model"] == 1_050_000)
    #expect(settings.defaults["test/model"] == 272_000)
    #expect(ModelContextSettings.empty.defaults["unknown/model"] == nil)
  }

  @Test func invalidLimitsCannotReachTheServer() {
    for input in [
      "0", "-1", "+1000", "1.5", "1e6", "1,000,000", "１０２４", "1000 tokens",
      "9007199254740992", "999999999999999999999999999999",
    ] {
      #expect(throws: ModelContextLimit.ValidationError.self) {
        try ModelContextLimit.parse(input)
      }
    }
  }
}
