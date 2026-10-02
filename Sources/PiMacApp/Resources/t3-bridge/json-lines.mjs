// Private IPC uses LF bytes, not JavaScript/Unicode line boundaries. Node's
// readline splits U+2028/U+2029 inside valid JSON strings emitted by Foundation.
export function createJSONLineReceiver(onMessage, {
  onInvalid = () => {}, maxBytes = 16 * 1024 * 1024,
} = {}) {
  let parts = [], bytes = 0, oversized = false;
  return chunk => {
    const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    let start = 0;
    while (start < data.length) {
      const lf = data.indexOf(0x0a, start);
      const end = lf < 0 ? data.length : lf;
      const part = data.subarray(start, end);
      bytes += part.length;
      if (bytes > maxBytes) { oversized = true; parts = []; }
      if (!oversized && part.length) parts.push(part);
      if (lf < 0) return;
      if (oversized) onInvalid();
      else if (bytes) {
        let line = Buffer.concat(parts, bytes);
        if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
        if (line.length) {
          try { onMessage(JSON.parse(line.toString('utf8'))); }
          catch { onInvalid(); }
        }
      }
      parts = []; bytes = 0; oversized = false;
      start = lf + 1;
    }
  };
}
