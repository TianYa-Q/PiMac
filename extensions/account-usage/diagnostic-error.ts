type ErrorDetails = {
  name: string;
  message?: string;
  code?: string;
  syscall?: string;
  cause?: ErrorDetails;
  errors?: ErrorDetails[];
};

const SAFE_NAMES = new Set([
  "Error",
  "TypeError",
  "RangeError",
  "SyntaxError",
  "ReferenceError",
  "URIError",
  "EvalError",
  "AggregateError",
  "AbortError",
  "TimeoutError",
  "HttpStatusError",
]);
const SAFE_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ETIMEDOUT",
  "ENOTFOUND",
  "EAI_AGAIN",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "EPIPE",
  "ABORT_ERR",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_BODY_TIMEOUT",
  "UND_ERR_SOCKET",
  "CERT_HAS_EXPIRED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
]);
const SAFE_SYSCALLS = new Set([
  "connect",
  "read",
  "write",
  "getaddrinfo",
  "recv",
  "send",
]);

/** Provider errors are untrusted, including name/code/syscall, not just message.
 * Bound recursive graphs and collections; never serialize arbitrary properties.
 */
export function describeQuotaError(value: unknown, depth = 0): ErrorDetails {
  if (!(value instanceof Error)) return { name: typeof value };
  const details: ErrorDetails = {
    name: SAFE_NAMES.has(value.name) ? value.name : "Error",
  };
  if (
    /^(fetch failed|This operation was aborted|The operation was aborted)$/iu.test(
      value.message,
    ) ||
    /^额度接口返回 HTTP \d{3}。$/u.test(value.message)
  )
    details.message = value.message;
  const nodeError = value as Error & { code?: unknown; syscall?: unknown };
  if (typeof nodeError.code === "string" && SAFE_CODES.has(nodeError.code))
    details.code = nodeError.code;
  if (
    typeof nodeError.syscall === "string" &&
    SAFE_SYSCALLS.has(nodeError.syscall)
  )
    details.syscall = nodeError.syscall;
  if (depth < 3) {
    if (value.cause !== undefined)
      details.cause = describeQuotaError(value.cause, depth + 1);
    if (value instanceof AggregateError && Array.isArray(value.errors))
      details.errors = value.errors
        .slice(0, 4)
        .map((error: unknown) => describeQuotaError(error, depth + 1));
  }
  return details;
}
