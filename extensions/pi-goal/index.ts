import goal from "@schovest/pi-goal";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export function goalStatus(data: unknown) {
  if (!data || typeof data !== "object" || !("goal" in data)) throw new Error("Missing goal-state payload");
  const value = data.goal;
  if (value === null) return { version: 1, goal: null };
  if (!value || typeof value !== "object") throw new Error("Invalid goal-state goal");
  const raw = value as Record<string, unknown>;
  const statuses = ["active", "paused", "blocked", "usage_limited", "budget_limited", "complete"];
  if (typeof raw.text !== "string" || !raw.text.trim() || raw.text.length > 4000 ||
      typeof raw.status !== "string" || !statuses.includes(raw.status)) throw new Error("Invalid goal objective/status");
  function counter(key: string) {
    const number = raw[key];
    if (typeof number !== "number" || !Number.isFinite(number) || number < 0) throw new Error(`Invalid goal ${key}`);
    return Math.floor(number);
  }
  const budget = raw.tokenBudget;
  if (budget !== undefined && (typeof budget !== "number" || !Number.isSafeInteger(budget) || budget <= 0)) {
    throw new Error("Invalid goal tokenBudget");
  }
  return { version: 1, goal: {
    objective: raw.text, status: raw.status,
    tokensUsed: counter("tokensUsed"), timeUsedSeconds: counter("timeUsedSeconds"),
    ...(budget === undefined ? {} : { tokenBudget: budget }),
    ...(raw.safetyPauseCause === "continuation_limit" ? { pauseReason: "已达到自动响应次数上限，检查进度后可继续执行。" } : {}),
    ...(raw.safetyPauseCause === "no_progress" ? { pauseReason: "连续自动执行未取得进展，请检查目标和执行结果。" } : {}),
  } };
}

/** 只观察扩展通过公开 appendEntry 写入的状态；不改命令、确认、调度或第三方源码。 */
export default function piMacGoal(pi: ExtensionAPI) {
  let context: ExtensionContext | undefined;
  let last: string | undefined;
  const publish = (data: unknown) => {
    if (!context || context.mode !== "rpc") return;
    try {
      const payload = JSON.stringify(goalStatus(data));
      if (payload === last) return;
      context.ui.setStatus("pimac-goal", payload);
      last = payload;
    } catch (error) {
      // 损坏不是合法空状态，保留已显示的目标并明确提示。
      context.ui.notify(`PiMac Goal state error: ${String(error)}`, "error");
    }
  };
  pi.on("session_start", (_event, ctx) => { context = ctx; last = undefined; });
  const adapter = new Proxy(pi, {
    get(target, property, receiver) {
      if (property !== "appendEntry") return Reflect.get(target, property, receiver);
      return (customType: string, data: unknown) => {
        target.appendEntry(customType, data);
        if (customType === "goal-state") publish(data);
      };
    },
  });
  goal(adapter);
  pi.on("session_start", (_event, ctx) => {
    const entries = ctx.sessionManager.getBranch();
    const entry = entries.findLast(item => item.type === "custom" && item.customType === "goal-state");
    publish(entry?.type === "custom" ? entry.data : { goal: null });
  });
  pi.on("session_shutdown", () => { context = undefined; last = undefined; });
}
