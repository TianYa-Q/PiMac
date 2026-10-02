// Provider-reported tokens only. Excludes tool waits; never estimates from text.
export class OutputSpeed {
  reset() { this.started = undefined; this.tokens = 0; this.duration = 0; this.current = 0; this.value = null; }
  constructor() { this.reset(); }
  consume(event, now = performance.now()) {
    if (event.type === 'message_start' && event.message?.role === 'assistant') {
      this.started = now; this.current = 0;
    } else if (event.type === 'message_update' && event.assistantMessageEvent) {
      const count = event.usage?.output ?? event.assistantMessageEvent.partial?.usage?.output;
      if (this.started !== undefined && Number.isFinite(count) && count > 0) {
        this.current = Math.max(this.current, count);
        const seconds = this.duration + (now - this.started) / 1000;
        if (seconds > 0) this.value = (this.tokens + this.current) / seconds;
      }
    } else if (event.type === 'message_end' && event.message?.role === 'assistant' && this.started !== undefined) {
      const count = event.message.usage?.output ?? this.current;
      const seconds = (now - this.started) / 1000;
      if (Number.isFinite(count) && count > 0 && seconds > 0) {
        this.tokens += count; this.duration += seconds;
        this.value = this.tokens / this.duration;
      }
      this.started = undefined; this.current = 0;
    }
  }
}
