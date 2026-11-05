import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

// 真实 Pi 的离线 Provider；只在隔离工作目录执行一次可观察的本地工具。
export default function (pi: any) {
  let mode = "recover";
  let calls = 0;
  pi.on("input", (event: any) => {
    mode = event.text;
    calls = 0;
  });
  pi.registerProvider("pimac-retry-test", {
    api: "pimac-retry-test", apiKey: "offline-only", baseUrl: "http://invalid.local",
    models: [{ id: "offline", name: "Offline retry regression", reasoning: false,
      input: ["text"], contextWindow: 200_000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    streamSimple(model: any, context: any) {
      const stream = createAssistantMessageEventStream();
      const call = calls++;
      const message: any = {
        role: "assistant", api: model.api, provider: model.provider, model: model.id,
        timestamp: Date.now(), content: [], stopReason: "stop",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      };
      stream.push({ type: "start", partial: message });
      if (mode === "recover" && call === 0) {
        const toolCall = { type: "toolCall" as const, id: "retry-side-effect", name: "bash",
          arguments: { command: "printf x >> retry-tool-count.txt" } };
        message.content = [toolCall];
        message.stopReason = "toolUse";
        stream.push({ type: "toolcall_start", contentIndex: 0, partial: message });
        stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: message });
      } else if (mode !== "recover" || call <= 7) {
        message.stopReason = "error";
        message.errorMessage = mode === "recover" || mode === "forever" ? "fetch failed" : mode;
        stream.push({ type: "error", reason: "error", error: message });
        stream.end();
        return stream;
      } else {
        const text = JSON.stringify({ calls,
          failedInContext: context.messages.filter((entry: any) => entry.role === "assistant" && entry.stopReason === "error").length,
          toolResults: context.messages.filter((entry: any) => entry.role === "toolResult").length });
        message.content = [{ type: "text", text }];
        stream.push({ type: "text_start", contentIndex: 0, partial: message });
        stream.push({ type: "text_end", contentIndex: 0, content: text, partial: message });
      }
      stream.push({ type: "done", reason: message.stopReason, message });
      stream.end();
      return stream;
    },
  });
}
