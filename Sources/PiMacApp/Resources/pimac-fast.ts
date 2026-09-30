// Pi Mac's per-process Fast preference. No global Pi settings are modified.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  let enabled = process.env.PIMAC_FAST_MODE === "1";
  const publish = (ctx: { ui: { setStatus(key: string, value: string): void } }) =>
    ctx.ui.setStatus("pimac-fast", enabled ? "on" : "off");

  pi.on("session_start", (_event, ctx) => publish(ctx));
  pi.registerCommand("pimac-fast", {
    description: "Set Pi Mac OpenAI/Codex Fast mode (on/off)",
    handler: async (args, ctx) => {
      if (!ctx.isIdle()) throw new Error("Wait until the current task finishes.");
      if (args.trim() !== "on" && args.trim() !== "off")
        throw new Error("Expected on or off.");
      enabled = args.trim() === "on";
      publish(ctx);
    },
  });
  pi.on("before_provider_request", (event, ctx) => {
    // Only native Responses models support this wire contract. ctx.model is the
    // selected model, not a virtual router's dispatched model: never alter a
    // request based on a virtual selection's provider alone.
    const model = ctx.model;
    if (!enabled || !model) return;
    if (model.provider !== "openai" && model.provider !== "openai-codex") return;
    if (model.api !== "openai-responses" && model.api !== "openai-codex-responses") return;
    if (event.payload && typeof event.payload === "object" && !Array.isArray(event.payload))
      return { ...event.payload, service_tier: "priority" };
  });
}
