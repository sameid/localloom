const STYLE = `
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0a0a0a;
    color: #888;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
    font-family: -apple-system, system-ui, sans-serif;
  }
  .container { max-width: 960px; width: 100%; padding: 20px; }
  .message { text-align: center; padding: 60px 20px; }
  h1 { color: #ccc; font-size: 24px; margin-bottom: 12px; }
  p { font-size: 16px; }
  video { width: 100%; border-radius: 12px; box-shadow: 0 20px 60px rgba(0,0,0,0.5); }
  .brand { color: #555; font-size: 13px; margin-top: 24px; text-align: center; }
`;

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function layout(title, body, head = '') {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  ${head}
  <style>${STYLE}</style>
</head>
<body>
${body}
</body>
</html>`;
}

function message(title, text, head) {
  return layout(title, `<div class="message"><h1>${escapeHtml(title)}</h1><p>${escapeHtml(text)}</p></div>`, head);
}

export function watch(id) {
  return layout(
    'LocalLoom Recording',
    `<div class="container">
  <video src="/media/${escapeHtml(id)}.mp4" controls autoplay playsinline preload="metadata"></video>
  <div class="brand">Shared via LocalLoom</div>
</div>`,
  );
}

export function uploading() {
  return message(
    'Almost ready',
    'This recording is still uploading. The page will refresh on its own.',
    '<meta http-equiv="refresh" content="5">',
  );
}

export function notFound() {
  return message('Recording Not Found', 'This recording may have been deleted or is no longer available.');
}

export function home() {
  return message('LocalLoom', 'Open a share link to watch a recording.');
}
