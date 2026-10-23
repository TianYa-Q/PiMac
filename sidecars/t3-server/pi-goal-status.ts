export interface PiGoalStatus {
  objective: string;
  status: "active" | "paused" | "blocked" | "budget_limited" | "complete";
  tokensUsed: number;
  timeUsedSeconds: number;
  tokenBudget?: number | null;
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid pi-goal-x status record");
  }
  return value as Record<string, unknown>;
}

function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error("Invalid pi-goal-x usage counter");
  }
  return value;
}

/** null 是明确的无目标；缺字段、未知版本和损坏 JSON 不能伪装成清空状态。 */
export function parsePiGoalStatus(text: unknown): PiGoalStatus | null {
  if (typeof text !== "string") throw new Error("Missing pi-goal-x status payload");
  const envelope = record(JSON.parse(text));
  if (envelope.version !== 1) throw new Error("Unsupported pi-goal-x status version");
  if (envelope.goal === null) return null;
  const goal = record(envelope.goal);
  if (typeof goal.objective !== "string" || !goal.objective.trim()) {
    throw new Error("Missing pi-goal-x objective");
  }
  const status = goal.status;
  if (status !== "active" && status !== "paused" && status !== "blocked" &&
      status !== "budget_limited" && status !== "complete") {
    throw new Error("Invalid pi-goal-x lifecycle status");
  }
  return {
    objective: goal.objective.trim(), status,
    tokensUsed: count(goal.tokensUsed), timeUsedSeconds: count(goal.timeUsedSeconds),
    ...(goal.tokenBudget === undefined ? {} : {
      tokenBudget: goal.tokenBudget === null ? null : count(goal.tokenBudget),
    }),
  };
}
