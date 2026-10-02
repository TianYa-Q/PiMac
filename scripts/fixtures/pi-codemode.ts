// Offline deterministic provider for the real Pi RPC/codemode integration test.
// No HTTP requests and no user credentials. It drives the normal agent/tool pipeline.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function (pi: any) {
  let turn = 0;
  let abortScenario = false;
  pi.on("input", (event: any) => {
    if (event.text === "compat-abort") {
      turn = 0;
      abortScenario = true;
    }
  });
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
  const scripts = [
    `const results = await Promise.all([tools.read({path: 'fixture.txt'}), tools.bash({command: 'printf codemode-shell'})]);
text(results); store('compat-state', 42);
const model = await models.getModelOfType('image', 'pimac-compat', 'fixture-image');
const generated = await models.generateImages(model, {input: [{type: 'text', text: 'offline fixture'}]});
if (generated.stopReason !== 'stop') throw new Error(generated.errorMessage);
for (const block of generated.output) image(block);`,
    "return load('compat-state');",
    "text('partial'); throw new Error('compat-script-error');",
  ];
  pi.registerProvider("pimac-compat", {
    api: "pimac-compat-api", apiKey: "synthetic-key", baseUrl: "http://invalid.local",
    models: [{ id: "offline", name: "Offline compatibility test", reasoning: false,
      input: ["text", "image"], contextWindow: 200000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } },
      { type: "image", id: "fixture-image", name: "Offline image fixture", api: "pimac-compat-images",
        baseUrl: "http://invalid.local", input: ["text"], output: ["image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    images: {
      "pimac-compat-images": { generateImages: async (model: any) => ({
        provider: model.provider, model: model.id, stopReason: "stop",
        output: [{ type: "image", data: png, mimeType: "image/png" }],
        usage: { input: 7, output: 2, totalTokens: 9,
          cost: { input: 0.01, output: 0.02, cacheRead: 0, cacheWrite: 0, total: 0.03 } },
      }) },
    },
    streamSimple(model: any) {
      const stream = createAssistantMessageEventStream();
      const index = turn++;
      const script = abortScenario
        ? (index === 0 ? "await tools.bash({command: 'sleep 30'});" : undefined)
        : scripts[index];
      const message: any = {
        role: "assistant", api: model.api, provider: model.provider, model: model.id,
        timestamp: Date.now(), content: [], stopReason: "pending",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      };
      stream.push({ type: "start", partial: message });
      if (script !== undefined) {
        const block = { type: "toolCall", id: `compat-code-${index}`, name: "codemode", arguments: { code: script } };
        message.content.push(block);
        stream.push({ type: "toolcall_start", contentIndex: 0, partial: message });
        stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(block.arguments), partial: message });
        stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: block, partial: message });
        message.stopReason = "toolUse";
      } else {
        message.content.push({ type: "text", text: "Offline codemode test complete" });
        stream.push({ type: "text_start", contentIndex: 0, partial: message });
        stream.push({ type: "text_delta", contentIndex: 0, delta: message.content[0].text, partial: message });
        stream.push({ type: "text_end", contentIndex: 0, content: message.content[0].text, partial: message });
        message.stopReason = "stop";
      }
      stream.push({ type: "done", reason: message.stopReason, message });
      stream.end();
      return stream;
    },
  });
}
