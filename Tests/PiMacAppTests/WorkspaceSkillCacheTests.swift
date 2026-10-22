import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct WorkspaceSkillCacheTests {
  private let key = WorkspaceSkillCache.Key(instanceID: "pi", cwd: "/project")
  private let now = Date(timeIntervalSince1970: 1_000)

  private func skill(_ name: String) throws -> ComposerSkill {
    try JSONDecoder().decode(
      ComposerSkill.self,
      from: JSONSerialization.data(withJSONObject: [
        "name": name, "path": "/skills/\(name)", "enabled": true,
      ]))
  }

  @Test func emptySuccessExpiresFromValidationTimeAndReadsNeverDiscover() async {
    let cache = WorkspaceSkillCache()
    var calls = 0
    let discover: @MainActor () async throws -> WorkspaceSkillCache.Success = {
      calls += 1
      return .init(skills: [], validatedAt: now.addingTimeInterval(-299))
    }
    await cache.preload(key: key, reload: .ifStale, now: now, discover: discover)?.value
    #expect(cache.state(for: key).success != nil)
    await cache.preload(key: key, reload: .ifStale, now: now, discover: discover)?.value
    #expect(calls == 1)
    for _ in 0..<10 { #expect(cache.state(for: key).skills.isEmpty) }
    #expect(cache.state(for: .init(instanceID: "other", cwd: "/missing")) == .idle)
    #expect(calls == 1)
    await cache.preload(
      key: key, reload: .ifStale, now: now.addingTimeInterval(1), discover: discover)?.value
    #expect(calls == 2)
  }

  @Test func staleRefreshRetainsSelectableSkillsAndFailureWithCooldown() async throws {
    let cache = WorkspaceSkillCache(clock: { now.addingTimeInterval(301) })
    let old = WorkspaceSkillCache.Success(skills: [try skill("old")], validatedAt: now)
    await cache.preload(key: key, reload: .ifStale, now: now) { old }?.value
    var completion: CheckedContinuation<WorkspaceSkillCache.Success, any Error>?
    let refresh = cache.preload(key: key, reload: .ifStale, now: now.addingTimeInterval(300)) {
      try await withCheckedThrowingContinuation { completion = $0 }
    }
    #expect(cache.state(for: key) == .loading(previous: old))
    #expect(SkillCompletion.matches(cache.state(for: key).skills, query: "old").count == 1)
    for _ in 0..<100 where completion == nil { await Task.yield() }
    try #require(completion).resume(throwing: CocoaError(.fileReadUnknown))
    await refresh?.value
    #expect(cache.state(for: key).success == old)
    #expect(cache.state(for: key).error != nil)
    var calls = 0
    await cache.preload(key: key, reload: .ifStale, now: now.addingTimeInterval(302)) {
      calls += 1
      return old
    }?.value
    #expect(calls == 0)
    await cache.preload(key: key, reload: .force, now: now.addingTimeInterval(302)) {
      calls += 1
      return .init(skills: [], validatedAt: now.addingTimeInterval(302))
    }?.value
    #expect(calls == 1)
    #expect(cache.state(for: key).skills.isEmpty)
    #expect(cache.state(for: key).error == nil)
  }

  @Test func initialFailureIsNotEmptySuccessAndForceRetriesIt() async {
    let cache = WorkspaceSkillCache(clock: { now })
    await cache.preload(key: key, reload: .ifStale, now: now) {
      throw CocoaError(.fileReadUnknown)
    }?.value
    #expect(cache.state(for: key).success == nil)
    #expect(cache.state(for: key).error != nil)
    await cache.preload(key: key, reload: .force, now: now) {
      .init(skills: [], validatedAt: now)
    }?.value
    #expect(cache.state(for: key).success != nil)
  }

  @Test(arguments: [false, true])
  func coalescesOwnersButForceSupersedesAutomaticResult(lateFailure: Bool) async throws {
    let cache = WorkspaceSkillCache()
    var calls = 0
    var completion: CheckedContinuation<WorkspaceSkillCache.Success, any Error>?
    let automatic = cache.preload(key: key, reload: .ifStale, now: now) {
      calls += 1
      return try await withCheckedThrowingContinuation { completion = $0 }
    }
    let joined = cache.preload(key: key, reload: .ifStale, now: now) {
      Issue.record("重复进入不应重复发现")
      return .init(skills: [], validatedAt: now)
    }
    for _ in 0..<100 where completion == nil { await Task.yield() }
    let newest = WorkspaceSkillCache.Success(skills: [try skill("new")], validatedAt: now)
    let force = cache.preload(key: key, reload: .force, now: now) { newest }
    let forceJoined = cache.preload(key: key, reload: .force, now: now) {
      Issue.record("重复显式刷新应加入正在进行的强制请求")
      return newest
    }
    await force?.value
    await forceJoined?.value
    if lateFailure {
      try #require(completion).resume(throwing: CocoaError(.fileReadUnknown))
    } else {
      try #require(completion).resume(returning: .init(skills: [], validatedAt: now))
    }
    await automatic?.value
    await joined?.value
    #expect(calls == 1)
    #expect(cache.state(for: key) == .ready(newest))
  }

  @Test(arguments: [false, true])
  func resetRejectsLateResultsWithoutClearingNewRequest(lateFailure: Bool) async throws {
    let cache = WorkspaceSkillCache()
    var completion: CheckedContinuation<WorkspaceSkillCache.Success, any Error>?
    let previous = cache.preload(key: key, reload: .ifStale, now: now) {
      try await withCheckedThrowingContinuation { completion = $0 }
    }
    for _ in 0..<100 where completion == nil { await Task.yield() }
    cache.reset()
    let newest = WorkspaceSkillCache.Success(skills: [try skill("new")], validatedAt: now)
    var newCompletion: CheckedContinuation<WorkspaceSkillCache.Success, Never>?
    let newRequest = cache.preload(key: key, reload: .ifStale, now: now) {
      await withCheckedContinuation { newCompletion = $0 }
    }
    for _ in 0..<100 where newCompletion == nil { await Task.yield() }
    if lateFailure {
      try #require(completion).resume(throwing: CocoaError(.fileReadUnknown))
    } else {
      try #require(completion).resume(returning: .init(skills: [], validatedAt: now))
    }
    await previous?.value
    #expect(cache.state(for: key) == .loading(previous: nil))
    let joined = cache.preload(key: key, reload: .ifStale, now: now) {
      Issue.record("旧请求不能清除新连接的请求")
      return newest
    }
    try #require(newCompletion).resume(returning: newest)
    await newRequest?.value
    await joined?.value
    #expect(cache.state(for: key) == .ready(newest))
    for scopedKey in [
      WorkspaceSkillCache.Key(instanceID: "pi", cwd: "/worktree"),
      .init(instanceID: "other", cwd: "/project"),
    ] {
      #expect(cache.state(for: scopedKey) == .idle)
      await cache.preload(key: scopedKey, reload: .ifStale, now: now) {
        .init(skills: [], validatedAt: now)
      }?.value
      #expect(cache.state(for: scopedKey).skills.isEmpty)
    }
    #expect(cache.state(for: key) == .ready(newest))
  }
}
