// One JSON object per line, so the macOS app (and log collectors) can parse it.
export function log(msg, fields = {}) {
  console.log(JSON.stringify({ time: new Date().toISOString(), msg, ...fields }));
}
