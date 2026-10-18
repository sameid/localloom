import { createReadStream } from 'node:fs';
import { createHash, timingSafeEqual } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { HttpError } from './store.js';
import { log } from './log.js';
import * as pages from './pages.js';

const MAX_JSON_BODY = 64 * 1024;
const PAGE_CSP = "default-src 'none'; media-src 'self'; style-src 'unsafe-inline'";

export function createHandler({ store, token, publicUrl = null }) {
  const tokenDigest = digest(token);

  const isAuthorized = (req) => {
    const match = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    return match !== null && timingSafeEqual(digest(match[1]), tokenDigest);
  };

  // The share URL comes from config when set. Otherwise it's derived from the request,
  // which is right when the client reaches the server at its public address.
  const shareUrl = (req, id) => {
    const base = publicUrl ?? `${forwarded(req, 'proto') ?? (req.socket.encrypted ? 'https' : 'http')}://${forwarded(req, 'host') ?? req.headers.host}`;
    return `${base}/v/${id}`;
  };

  const recordingJson = async (req, meta) => ({
    ...meta,
    offset: meta.status === 'ready' ? meta.size : await store.received(meta.id),
    share_url: shareUrl(req, meta.id),
  });

  // [method, path pattern, needs auth, handler]. Captured IDs are matched against the raw,
  // still-encoded path, so "%2F" can never become a path separator.
  const routes = [
    ['GET', /^\/healthz$/, false, (req, res) => sendText(res, 200, 'ok')],
    ['GET', /^\/$/, false, (req, res) => sendHtml(res, 200, pages.home())],
    ['GET', /^\/v\/([^/]+)$/, false, async (req, res, id) => {
      const meta = await store.get(id);
      if (!meta) return sendHtml(res, 404, pages.notFound());
      if (meta.status !== 'ready') return sendHtml(res, 200, pages.uploading());
      return sendHtml(res, 200, pages.watch(id));
    }],
    ['GET', /^\/media\/([^/]+)\.mp4$/, false, async (req, res, id) => {
      const meta = await store.get(id);
      if (!meta || meta.status !== 'ready') return sendText(res, 404, 'not found');
      await sendVideo(req, res, store.videoPath(id), meta.size);
    }],

    ['GET', /^\/api\/status$/, true, (req, res) => sendJson(res, 200, { ok: true, public_url: publicUrl })],
    ['GET', /^\/api\/recordings$/, true, async (req, res) => {
      const metas = await store.list();
      sendJson(res, 200, { recordings: await Promise.all(metas.map((m) => recordingJson(req, m))) });
    }],
    ['POST', /^\/api\/recordings$/, true, async (req, res) => {
      const body = await readJson(req);
      const { meta, created } = await store.create({ id: body.id, size: body.size, duration: body.duration });
      if (created) log('recording created', { id: meta.id, size: meta.size });
      sendJson(res, created ? 201 : 200, await recordingJson(req, meta));
    }],
    ['GET', /^\/api\/recordings\/([^/]+)$/, true, async (req, res, id) => {
      const meta = await store.get(id);
      if (!meta) throw new HttpError(404, 'not found');
      sendJson(res, 200, await recordingJson(req, meta));
    }],
    ['PUT', /^\/api\/recordings\/([^/]+)\/content$/, true, async (req, res, id) => {
      const offsetHeader = req.headers['upload-offset'];
      if (!/^\d+$/.test(offsetHeader ?? '')) throw new HttpError(400, 'Upload-Offset header is required');
      const offset = await store.append(id, Number(offsetHeader), req);
      sendJson(res, 200, { offset });
    }],
    ['POST', /^\/api\/recordings\/([^/]+)\/complete$/, true, async (req, res, id) => {
      const meta = await store.complete(id);
      log('recording ready', { id, size: meta.size });
      sendJson(res, 200, await recordingJson(req, meta));
    }],
    ['DELETE', /^\/api\/recordings\/([^/]+)$/, true, async (req, res, id) => {
      await store.remove(id);
      log('recording deleted', { id });
      res.writeHead(204).end();
    }],
  ];

  return async function handle(req, res) {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Robots-Tag', 'noindex, nofollow');

    try {
      const { pathname } = new URL(req.url, 'http://localhost');
      const method = req.method === 'HEAD' ? 'GET' : req.method;

      let pathMatched = false;
      for (const [routeMethod, pattern, needsAuth, handler] of routes) {
        const match = pattern.exec(pathname);
        if (!match) continue;
        pathMatched = true;
        if (routeMethod !== method) continue;
        if (needsAuth && !isAuthorized(req)) {
          res.setHeader('WWW-Authenticate', 'Bearer');
          throw new HttpError(401, 'missing or invalid token');
        }
        return await handler(req, res, ...match.slice(1));
      }
      if (pathMatched) throw new HttpError(405, 'method not allowed');
      if (pathname.startsWith('/api/')) throw new HttpError(404, 'not found');
      sendHtml(res, 404, pages.notFound());
    } catch (err) {
      // Viewers drop video connections all the time while seeking; that's not an error.
      if (res.headersSent) {
        res.destroy();
        return;
      }
      if (err instanceof HttpError) {
        sendJson(res, err.status, { error: err.message, ...err.extra });
      } else {
        log('request failed', { method: req.method, url: req.url, error: err.stack ?? String(err) });
        sendJson(res, 500, { error: 'internal error' });
      }
    }
  };
}

// Supports a single "bytes=" range, which is what browsers send for video seeking.
export function parseRange(header, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return null; // Multi-range or malformed: ignore and send the whole file.
  const [, startText, endText] = match;

  let start;
  let end;
  if (startText === '') {
    const suffix = Number(endText);
    if (endText === '' || suffix === 0) return 'unsatisfiable';
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(startText);
    end = endText === '' ? size - 1 : Math.min(Number(endText), size - 1);
  }
  if (start > end || start >= size) return 'unsatisfiable';
  return { start, end };
}

async function sendVideo(req, res, file, size) {
  const range = req.headers.range ? parseRange(req.headers.range, size) : null;
  if (range === 'unsatisfiable') {
    res.writeHead(416, { 'Content-Range': `bytes */${size}` }).end();
    return;
  }

  const { start, end } = range ?? { start: 0, end: size - 1 };
  res.writeHead(range ? 206 : 200, {
    'Content-Type': 'video/mp4',
    'Content-Length': end - start + 1,
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-cache',
    ...(range && { 'Content-Range': `bytes ${start}-${end}/${size}` }),
  });
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  await pipeline(createReadStream(file, { start, end }), res);
}

async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_JSON_BODY) throw new HttpError(413, 'request body too large');
    chunks.push(chunk);
  }
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    if (typeof body !== 'object' || body === null || Array.isArray(body)) throw new Error();
    return body;
  } catch {
    throw new HttpError(400, 'body must be a JSON object');
  }
}

function forwarded(req, name) {
  return req.headers[`x-forwarded-${name}`]?.split(',')[0].trim() || null;
}

function digest(value) {
  return createHash('sha256').update(value).digest();
}

function sendText(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' }).end(text);
}

function sendHtml(res, status, html) {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy': PAGE_CSP,
  }).end(html);
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
}
