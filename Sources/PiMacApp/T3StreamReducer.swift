import Foundation
import JavaScriptCore

/// JavaScriptCore 只运行固定资源中的官方纯 reducer，不执行会话文字或工具代码。
/// 放在独立 actor 上，避免协议解码、投影合并和历史序列化阻塞主线程。
actor T3StreamReducer {
  enum Kind: String { case shell, thread }
  enum Failure: Error { case missingResource, invalidRuntime, invalidFrame }
  private struct Runtime {
    let context: JSContext
    let state: JSValue
  }
  private let kind: Kind
  private var loadedRuntime: Runtime?

  init(kind: Kind) { self.kind = kind }

  private func runtime() throws -> Runtime {
    if let loadedRuntime { return loadedRuntime }
    guard let url = Bundle.module.url(forResource: "t3-client-state", withExtension: "js") else {
      throw Failure.missingResource
    }
    guard let context = JSContext() else { throw Failure.invalidRuntime }
    // 独立 JSC 没有浏览器的 UTF-8 API；Schema 的二进制工具会在模块加载时创建它们。
    let encode: @convention(block) (String) -> [UInt8] = { Array($0.utf8) }
    let decode: @convention(block) ([NSNumber], Bool) -> String? = { bytes, fatal in
      let data = Data(bytes.map(\.uint8Value))
      return fatal ? String(data: data, encoding: .utf8) : String(decoding: data, as: UTF8.self)
    }
    context.setObject(encode, forKeyedSubscript: "__t3EncodeUTF8" as NSString)
    context.setObject(decode, forKeyedSubscript: "__t3DecodeUTF8" as NSString)
    context.evaluateScript(
      """
      class TextEncoder {
        get encoding() { return 'utf-8'; }
        encode(text = '') { return Uint8Array.from(__t3EncodeUTF8(String(text))); }
      }
      class TextDecoder {
        constructor(label = 'utf-8', options = {}) {
          if (!['utf-8', 'utf8', 'unicode-1-1-utf-8'].includes(label.toLowerCase().trim()))
            throw new RangeError('Only UTF-8 is supported by this native host');
          this.fatal = Boolean(options.fatal); this.ignoreBOM = Boolean(options.ignoreBOM);
        }
        get encoding() { return 'utf-8'; }
        decode(input = new Uint8Array(), options = {}) {
          if (options.stream) throw new TypeError('Streaming byte decoding is not supported');
          const bytes = ArrayBuffer.isView(input)
            ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength) : new Uint8Array(input);
          const text = __t3DecodeUTF8(Array.from(bytes), this.fatal);
          if (text === null || text === undefined) throw new TypeError('Invalid UTF-8');
          return !this.ignoreBOM && text.startsWith('\\uFEFF') ? text.slice(1) : text;
        }
      }
      """)
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
    guard context.exception == nil,
      let state = context.objectForKeyedSubscript("T3NativeState")?
        .invokeMethod("createStreamState", withArguments: [kind.rawValue]),
      !state.isUndefined, context.exception == nil
    else { throw Failure.invalidRuntime }
    let result = Runtime(context: context, state: state)
    loadedRuntime = result
    return result
  }

  func apply(_ item: ImmutableJSONSnapshot) throws -> Bool {
    let runtime = try runtime()
    let context = runtime.context
    let state = runtime.state
    let data = try JSONSerialization.data(withJSONObject: item.value)
    context.exception = nil
    let result = state.invokeMethod("apply", withArguments: [String(decoding: data, as: UTF8.self)])
    guard context.exception == nil, let result, result.isBoolean else { throw Failure.invalidFrame }
    return result.toBool()
  }

  func snapshot() throws -> ImmutableJSONSnapshot {
    let runtime = try runtime()
    let context = runtime.context
    let state = runtime.state
    context.exception = nil
    guard let text = state.invokeMethod("snapshot", withArguments: [])?.toString(),
      context.exception == nil,
      let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw Failure.invalidFrame }
    return ImmutableJSONSnapshot(value: value)
  }
}
