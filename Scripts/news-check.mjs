#!/usr/bin/env node
// 앱 안 '소식' 의 규칙 (Docs/InAppNews.md) 을 그대로 옮긴 참고 구현 + 올리기 전 검사기.
//
//   node Scripts/news-check.mjs                       site/news/news.json 검사 + 공유 벡터 자체 시험
//   node Scripts/news-check.mjs site/news/news.json   소식 파일만 검사 (배포 전 — .github/workflows/pages.yml)
//   node Scripts/news-check.mjs --fixtures [파일]      Tests/Fixtures/news-rules.json 의 모든 벡터를 이 구현으로 돌려 보고,
//                                                    Docs/InAppNews.md 가 벡터와 같은 말을 하는지 (§1.3 문구 표 · 아이콘 · §7 의 sha256 · 크기) 본다
//
// 앱은 이 파일을 쓰지 않는다. Mac · iPhone · iPad 는 SpiraldayKit, Windows · Android 는 web/ 의 자기 구현이 같은 벡터
// (Tests/Fixtures/news-rules.json — 비공개 저장소 web/tests/fixtures/ 에 같은 바이트) 를 통과해야 한다.
// Node 18 이상, 의존성 없음.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const LIMITS = Object.freeze({
  maxBytes: 65536, maxItems: 50, maxDepth: 16, idMax: 64, titleMax: 80, bodyMax: 600, linkMax: 200, seenMax: 200,
});
export const PLATFORMS = Object.freeze(['mac', 'win', 'ios', 'ipados', 'android']);

// 정규식은 ASCII 만, 끝은 문자열 끝 (JS 의 $ 는 m 플래그가 없으면 맨 끝만 — Swift 는 \z 나 글자 검사로)
const ID_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const DATE_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const VERSION_RE = /^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$/;
const LINK_RE = /^https:\/\/spiralday\.com\/[A-Za-z0-9._~/-]*(#[A-Za-z0-9._~-]*)?$/;
// 제어 문자(C0 · DEL · C1) · 방향 제어 · 줄 · 문단 구분자. 본문은 \n (U+000A) 하나만 허용
const BAD_TEXT = /[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]/;

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const codePoints = (s) => [...s].length;
const absent = (v) => v === undefined || v === null;

export function parseVersion(s) {
  if (typeof s !== 'string' || !VERSION_RE.test(s)) return null;
  const p = s.split('.').map((x) => parseInt(x, 10));
  while (p.length < 3) p.push(0);
  return p;
}

export function compareVersions(a, b) {
  const x = parseVersion(a);
  const y = parseVersion(b);
  if (!x || !y) throw new Error(`not a version: ${a} / ${b}`);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}

export function isDate(s) {
  if (typeof s !== 'string' || !DATE_RE.test(s)) return false;
  const [y, m, d] = s.split('-').map((x) => parseInt(x, 10));
  if (y < 1 || m < 1 || m > 12 || d < 1) return false;
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
  return d <= days;
}

export function isAllowedLink(s) {
  return typeof s === 'string' && s.length <= LIMITS.linkMax && LINK_RE.test(s);
}

/** {ko, en?} → 정규화한 값 또는 null (항목을 버린다). en 이 없거나 null · "" 이면 ko 로 대신한다 */
function text(v, max, multiline) {
  if (!isObject(v)) return null;
  const ok = (s) => typeof s === 'string' && s.length > 0 && codePoints(s) <= max && !BAD_TEXT.test(s) && (multiline || !s.includes('\n'));
  if (!ok(v.ko)) return null;
  if (absent(v.en) || v.en === '') return { ko: v.ko };
  if (!ok(v.en)) return null;
  return { ko: v.ko, en: v.en };
}

function versionMap(v) {
  if (!isObject(v)) return null;
  for (const k of Object.keys(v)) if (parseVersion(v[k]) === null) return null;
  return { ...v };
}

/** 한 항목 → { item } 또는 { drop: 까닭 } */
export function validateItem(raw) {
  if (!isObject(raw)) return { drop: 'not an object' };
  if (typeof raw.id !== 'string' || !ID_RE.test(raw.id)) return { drop: 'id' };
  if (raw.id.startsWith('app-')) return { drop: 'id app- is reserved' };
  if (!isDate(raw.date)) return { drop: 'date' };
  if (raw.kind !== 'notice' && raw.kind !== 'update') return { drop: 'kind' };
  if (raw.importance !== 'normal' && raw.importance !== 'important') return { drop: 'importance' };
  const title = text(raw.title, LIMITS.titleMax, false);
  if (!title) return { drop: 'title' };
  const body = text(raw.body, LIMITS.bodyMax, true);
  if (!body) return { drop: 'body' };
  let platforms = null;
  if (!absent(raw.platforms)) {
    if (!Array.isArray(raw.platforms) || raw.platforms.length === 0 || !raw.platforms.every((p) => typeof p === 'string')) return { drop: 'platforms' };
    platforms = [...raw.platforms];
  }
  let minVersion = null;
  if (!absent(raw.minVersion) && !(minVersion = versionMap(raw.minVersion))) return { drop: 'minVersion' };
  let maxVersion = null;
  if (!absent(raw.maxVersion) && !(maxVersion = versionMap(raw.maxVersion))) return { drop: 'maxVersion' };
  if (!absent(raw.syncOnly) && typeof raw.syncOnly !== 'boolean') return { drop: 'syncOnly' };
  if (!absent(raw.expires) && !isDate(raw.expires)) return { drop: 'expires' };
  const linkOk = absent(raw.link) || isAllowedLink(raw.link);
  return {
    item: {
      id: raw.id, date: raw.date, kind: raw.kind, importance: raw.importance, title, body,
      platforms, minVersion, maxVersion, syncOnly: raw.syncOnly === true,
      link: !absent(raw.link) && linkOk ? raw.link : null,
      expires: absent(raw.expires) ? null : raw.expires,
    },
    linkRemoved: !linkOk,
  };
}

/**
 * 파서를 거치기 전, 적힌 그대로의 글 (§2.1 '어디에든' — 같은 키가 두 번 나와 덮어써지는 앞의 값까지. JSON.parse 는 뒤의 값만
 * 남기지만 Mac · iPhone · iPad 의 파서는 앞의 값도 본다): 객체 · 배열은 16단계까지 (맨 위 객체가 1), 서로게이트를 적은 \u escape 는
 * 모두 짝이 맞는다. JSON.parse 가 받아들인 글에만 쓴다 (escape 꼴은 이미 맞다). UTF-8 을 푼 글 자체에는 짝 없는 서로게이트가 없다.
 */
export function rawJsonOk(text) {
  let depth = 0;
  const hex = (at) => parseInt(text.slice(at, at + 4), 16);
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 0x7b || c === 0x5b) {
      if (++depth > LIMITS.maxDepth) return false;
    } else if (c === 0x7d || c === 0x5d) depth--;
    else if (c === 0x22) {
      // 문자열 (키든 값이든): 닫는 따옴표까지
      for (i++; i < text.length && text.charCodeAt(i) !== 0x22; i++) {
        if (text.charCodeAt(i) !== 0x5c) continue;
        i++;
        if (text[i] !== 'u') continue;
        const u = hex(i + 1);
        i += 4;
        if (u >= 0xdc00 && u <= 0xdfff) return false;
        if (u >= 0xd800 && u <= 0xdbff) {
          const low = text[i + 1] === '\\' && text[i + 2] === 'u' ? hex(i + 3) : -1;
          if (!(low >= 0xdc00 && low <= 0xdfff)) return false;
          i += 6;
        }
      }
    }
  }
  return true;
}

/** 같은 객체 안에 두 번 나온 키들 (올리기 전 검사의 오류 — 파서마다 다르게 읽을 수 있다). JSON.parse 가 받아들인 글에만 쓴다 */
export function duplicateKeys(text) {
  const out = [];
  const stack = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '{') stack.push({ keys: new Set(), expectKey: true });
    else if (c === '[') stack.push(null);
    else if (c === '}' || c === ']') stack.pop();
    else if (c === ',') {
      const top = stack[stack.length - 1];
      if (top) top.expectKey = true;
    } else if (c === '"') {
      const start = i;
      for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\') i++;
      const top = stack[stack.length - 1];
      if (top && top.expectKey) {
        const key = JSON.parse(text.slice(start, i + 1));
        if (top.keys.has(key)) out.push(key);
        else top.keys.add(key);
        top.expectKey = false;
      }
    }
  }
  return out;
}

/** 받은 바이트 → { accepted:false, reason } 또는 { accepted:true, items, dropped, linkRemoved } */
export function parseFeed(bytes) {
  let b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (b.length > LIMITS.maxBytes) return { accepted: false, reason: 'too big' };
  if (b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) b = b.subarray(3);
  let doc;
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(b);
    doc = JSON.parse(text);
  } catch {
    return { accepted: false, reason: 'not JSON (UTF-8)' };
  }
  if (!rawJsonOk(text)) return { accepted: false, reason: 'too deep or lone surrogate (an overwritten duplicate key counts too)' };
  if (!isObject(doc)) return { accepted: false, reason: 'not an object' };
  if (typeof doc.version !== 'number' || doc.version !== 1) return { accepted: false, reason: 'version' };
  if (!Array.isArray(doc.items)) return { accepted: false, reason: 'items' };
  const items = [];
  const dropped = [];
  const linkRemoved = [];
  const ids = new Set();
  doc.items.slice(0, LIMITS.maxItems).forEach((raw, index) => {
    const r = validateItem(raw);
    if (!r.item) return dropped.push({ index, id: isObject(raw) ? raw.id : undefined, reason: r.drop });
    if (ids.has(r.item.id)) return dropped.push({ index, id: r.item.id, reason: 'duplicate id' });
    ids.add(r.item.id);
    if (r.linkRemoved) linkRemoved.push(r.item.id);
    items.push(r.item);
  });
  if (doc.items.length > LIMITS.maxItems) dropped.push({ index: LIMITS.maxItems, reason: `items after the first ${LIMITS.maxItems} are not read` });
  return { accepted: true, items, dropped, linkRemoved };
}

/** 앱에 넣은 whats-new.json → 쓸 수 있는 노트들 (잘못된 것은 건너뛴다) */
export function parseBundled(doc) {
  if (!isObject(doc) || doc.version !== 1 || !Array.isArray(doc.notes)) return [];
  const out = [];
  for (const n of doc.notes) {
    if (!isObject(n) || parseVersion(n.app) === null || !isDate(n.date)) continue;
    const body = text(n.body, LIMITS.bodyMax, true);
    if (body) out.push({ app: n.app, date: n.date, body });
  }
  return out;
}

export function isVisible(item, env) {
  if (item.date > env.today) return false;
  if (item.expires !== null && env.today > item.expires) return false;
  if (item.platforms !== null && !item.platforms.includes(env.platform)) return false;
  const has = (m, k) => Object.prototype.hasOwnProperty.call(m, k);
  const key = (m) => (m === null ? null : has(m, env.platform) ? env.platform : env.platform === 'ipados' && has(m, 'ios') ? 'ios' : null);
  const minKey = key(item.minVersion);
  const maxKey = key(item.maxVersion);
  if (minKey !== null || maxKey !== null) {
    if (parseVersion(env.appVersion) === null) return false;
    if (minKey !== null && compareVersions(env.appVersion, item.minVersion[minKey]) < 0) return false;
    if (maxKey !== null && compareVersions(env.appVersion, item.maxVersion[maxKey]) > 0) return false;
  }
  if (item.syncOnly && !env.syncOn) return false;
  return true;
}

const pick = (t, lang) => (lang === 'ko' ? t.ko : t.en ?? t.ko);

/** 이 버전의 노트 (없으면 null) → 목록에 끼우는 항목 */
function noteFor(env, notes) {
  if (parseVersion(env.appVersion) === null) return null;
  const note = notes.find((n) => compareVersions(n.app, env.appVersion) === 0);
  return note ? {
    id: `app-${note.app}`, app: note.app, date: note.date, kind: 'update', importance: 'normal', link: null,
    title: { ko: `${note.app} 에서 달라진 점`, en: `What’s new in ${note.app}` }, body: note.body,
  } : null;
}

/** 보이는 항목: 이 버전의 노트 + 걸러 낸 소식, 날짜가 늦은 것부터 (같은 날이면 노트 먼저, 그다음 파일 순서) */
function ordered(env, items, notes) {
  const note = noteFor(env, notes);
  return [...(note ? [note] : []), ...items.filter((it) => isVisible(it, env))]
    .map((it, i) => ({ it, i }))
    .sort((a, b) => (a.it.date === b.it.date ? a.i - b.i : a.it.date < b.it.date ? 1 : -1))
    .map((x) => x.it);
}

function remember(seen, id) {
  if (!seen.includes(id)) seen.push(id);
  while (seen.length > LIMITS.seenMax) seen.shift();
}

/**
 * 한 번 '열 때' (Docs/InAppNews.md §5). env: platform · appVersion · today · lang · syncOn · firstRun,
 * state: lastSeenAppVersion · since · seen, items: parseFeed 가 받아들인 항목 (받아 둔 것이 없으면 []), notes: parseBundled
 * → { card, save } — card 는 지금 띄울 것 하나 (없으면 null), save 는 바로 저장할 상태 (카드는 띄우는 순간 본 것)
 */
export function open({ env, state, items, notes }) {
  const seen = [...(state.seen ?? [])];
  let lastSeen = state.lastSeenAppVersion ?? null;
  let since = state.since ?? null;
  const appOk = parseVersion(env.appVersion) !== null;
  const lastOk = lastSeen !== null && parseVersion(lastSeen) !== null;
  const note = noteFor(env, notes);
  let card = null;
  if (env.firstRun) {
    if (appOk && !(lastOk && compareVersions(lastSeen, env.appVersion) > 0)) lastSeen = env.appVersion;
    if (since === null) since = env.today;
    if (note) remember(seen, note.id);
  } else {
    const updated = appOk && (!lastOk || compareVersions(lastSeen, env.appVersion) < 0);
    const whatsNewDue = updated && note !== null && !seen.includes(note.id);
    const notice = ordered(env, items, notes).find((it) => it.importance === 'important' && !seen.includes(it.id));
    if (notice) {
      card = { type: 'notice', id: notice.id };
      remember(seen, notice.id);
    } else if (whatsNewDue) {
      card = { type: 'whatsNew', app: note.app };
      remember(seen, note.id);
    }
    if (updated && (!whatsNewDue || card?.type === 'whatsNew')) lastSeen = env.appVersion;
  }
  return { card, save: { lastSeenAppVersion: lastSeen, since, seen } };
}

/** 설정 › 소식 의 목록과 점 (상태를 바꾸지 않는다). 목록을 열면 앱이 seen 에 목록의 id 를 모두 더한다 */
export function list({ env, state, items, notes }) {
  const seen = state.seen ?? [];
  const since = state.since ?? null;
  const rows = ordered(env, items, notes).map((it) => ({
    id: it.id,
    title: pick(it.title, env.lang),
    body: pick(it.body, env.lang),
    link: it.link,
    unseen: !seen.includes(it.id) && (it.importance === 'important' || since === null || it.date >= since),
  }));
  return { list: rows, dot: rows.some((x) => x.unseen) };
}

/** 목록을 열었을 때: 보이는 것을 모두 본 것으로 */
export function markListSeen({ env, state, items, notes }) {
  const seen = [...(state.seen ?? [])];
  for (const it of ordered(env, items, notes)) remember(seen, it.id);
  return { ...state, seen };
}

const MONTHS_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * 목록 줄 · 카드 위 작은 글자의 날짜 (Docs/InAppNews.md §1.2 · §1.3): 올해면 ‘10월 20일’ · ‘Oct 20’, 아니면 ‘2025년 12월 3일’ · ‘Dec 3, 2025’.
 * 달력 날짜 글 그대로 — 시각(UTC)으로 바꾸지 않는다. 날짜 꼴이 아니면 글 그대로
 */
export function dateLabel(date, today, lang) {
  if (!isDate(date)) return date;
  const [y, m, d] = date.split('-').map((x) => parseInt(x, 10));
  const thisYear = typeof today === 'string' && today.slice(0, 4) === date.slice(0, 4);
  if (lang === 'ko') return thisYear ? `${m}월 ${d}일` : `${y}년 ${m}월 ${d}일`;
  return thisYear ? `${MONTHS_EN[m - 1]} ${d}` : `${MONTHS_EN[m - 1]} ${d}, ${y}`;
}

// MARK: - 공유 벡터 (Tests/Fixtures/news-rules.json)

/** 벡터 안의 {"$repeat": X, "times": n} 를 펼친다 (Docs/InAppNews.md §7) */
export function expand(v) {
  if (Array.isArray(v)) {
    const out = [];
    for (const x of v) {
      if (isObject(x) && '$repeat' in x && isObject(x.$repeat)) {
        for (let n = 1; n <= x.times; n++) out.push({ ...expand(x.$repeat), id: `${x.$repeat.id}-${n}` });
      } else out.push(expand(x));
    }
    return out;
  }
  if (isObject(v)) {
    if ('$repeat' in v && typeof v.$repeat === 'string') return v.$repeat.repeat(v.times);
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, expand(x)]));
  }
  return v;
}

/** 벡터의 feed (이름 · 객체 · feedText · feedBase64 · bom · padToBytes) → 바이트 (feed 가 null 이면 null — 받아 둔 것 없음) */
export function feedBytes(fx, c) {
  let s;
  if (typeof c.feedBase64 === 'string') return Buffer.from(c.feedBase64, 'base64');
  if (typeof c.feedText === 'string') s = c.feedText;
  else if (c.feed === null || c.feed === undefined) return null;
  else s = JSON.stringify(expand(typeof c.feed === 'string' ? fx.feeds[c.feed] : c.feed));
  let bytes = Buffer.from(s, 'utf8');
  if (c.bom) bytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), bytes]);
  if (c.padToBytes) bytes = Buffer.concat([bytes, Buffer.alloc(c.padToBytes - bytes.length, 0x20)]);
  return bytes;
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function runFixtures(file) {
  const fx = JSON.parse(fs.readFileSync(file, 'utf8'));
  const fails = [];
  let n = 0;
  const check = (where, got, want) => {
    n++;
    if (!same(got, want)) fails.push(`${where}\n    want ${JSON.stringify(want)}\n    got  ${JSON.stringify(got)}`);
  };
  check('limits', fx.limits, { ...LIMITS });
  for (const [s, ok] of fx.dates) check(`dates ${JSON.stringify(s)}`, isDate(s), ok);
  for (const [s, ok] of fx.versions.valid) check(`versions.valid ${JSON.stringify(s)}`, parseVersion(s) !== null, ok);
  for (const [a, b, c] of fx.versions.compare) check(`versions.compare ${a} ${b}`, compareVersions(a, b), c);
  for (const [s, ok] of fx.links) check(`links ${JSON.stringify(s)}`, isAllowedLink(s), ok);
  for (const c of fx.parse) {
    const r = parseFeed(feedBytes(fx, c));
    const got = r.accepted ? { accepted: true, ids: r.items.map((x) => x.id), ...(c.expect.links ? { links: Object.fromEntries(r.items.map((x) => [x.id, x.link])) } : {}) } : { accepted: false };
    check(`parse: ${c.name}`, got, c.expect);
  }
  for (const c of fx.select) {
    const bytes = feedBytes(fx, c);
    const parsed = bytes ? parseFeed(bytes) : null;
    if (bytes && !parsed.accepted) {
      fails.push(`select: ${c.name} — the feed is not accepted (${parsed.reason})`);
      continue;
    }
    const env = { ...fx.selectDefaults.env, ...c.env };
    const state = { ...fx.selectDefaults.state, ...c.state };
    const notes = parseBundled(typeof c.bundled === 'string' ? fx.bundled[c.bundled] : c.bundled ?? fx.bundled[fx.selectDefaults.bundled]);
    const items = parsed ? parsed.items : [];
    const r = open({ env, state, items, notes });
    const v = list({ env, state: r.save, items, notes });
    check(`select: ${c.name}`, { card: r.card, save: r.save, list: v.list, dot: v.dot }, c.expect);
    // 그 뒤 설정 › 소식을 열면 점이 모두 사라진다
    check(`select: ${c.name} — after opening the list`, list({ env, state: markListSeen({ env, state: r.save, items, notes }), items, notes }).dot, false);
  }
  for (const c of fx.fetch) {
    const r = c.expect;
    // 응답 처리: 200 이고 parseFeed 가 받아들일 때만 바꾼다. 나머지(304 · 3xx · 4xx · 5xx · 시간 초과 · 연결 실패 · 큰 · 깨진 본문)는 그대로
    const body = c.body === 'valid' ? Buffer.from('{"version":1,"items":[]}') : c.body === 'invalid' ? Buffer.from('{"version":2,"items":[]}') : c.body === 'tooBig' ? Buffer.alloc(LIMITS.maxBytes + 1, 0x20) : null;
    const got = c.status === 200 && body && parseFeed(body).accepted ? 'replace' : 'keep';
    check(`fetch: ${c.name}`, got, r);
  }
  for (const [date, today, lang, label] of fx.dateLabels) check(`dateLabels ${date} (today ${today}, ${lang})`, dateLabel(date, today, lang), label);
  for (const [key, t] of Object.entries(fx.copy)) check(`copy.${key}`, copyProblems(t), []);
  check('icon', /^#[0-9A-F]{6}$/.test(fx.icon.tint) && typeof fx.icon.symbol === 'string' && fx.icon.symbol !== '', true);
  return { n, fails };
}

const placeholders = (s) => (s.match(/\{[A-Za-z]+\}/g) ?? []).sort();

/** 문구 한 줄 { ko, en } 의 문제들 (없으면 []): 둘 다 있고, 한 줄이고, 자리 표시({date} …)가 같고, en 에 곧은 따옴표가 없다 */
export function copyProblems(t) {
  const out = [];
  if (!isObject(t)) return ['not { ko, en }'];
  for (const lang of ['ko', 'en']) {
    const s = t[lang];
    if (typeof s !== 'string' || s.trim() === '' || s !== s.trim()) out.push(`${lang}: empty or padded`);
    else if (BAD_TEXT.test(s) || s.includes('\n')) out.push(`${lang}: a control character or a line break`);
  }
  if (out.length) return out;
  if (JSON.stringify(placeholders(t.ko)) !== JSON.stringify(placeholders(t.en))) out.push('ko and en have different placeholders');
  if (/['"]/.test(t.en)) out.push("en: a straight quote (use ’)");
  return out;
}

/** 이 저장소의 사양(Docs/InAppNews.md)이 벡터와 같은 말을 하는지: §1.3 의 문구 표 · 아이콘, §7 의 바이트(sha256 · 크기) */
export function checkSpec(fixtureFile, docFile) {
  const bytes = fs.readFileSync(fixtureFile);
  const fx = JSON.parse(bytes.toString('utf8'));
  const doc = fs.readFileSync(docFile, 'utf8');
  const fails = [];
  let n = 0;
  const rows = new Map();
  for (const line of doc.split('\n')) {
    const m = /^\| `([A-Za-z]+)` \|(.*)\|$/.exec(line);
    if (m) rows.set(m[1], m[2].split('|').map((c) => c.trim()));
  }
  for (const [key, t] of Object.entries(fx.copy)) {
    n++;
    const cells = rows.get(key);
    if (!cells) fails.push(`${path.basename(docFile)} §1.3: no row for copy.${key}`);
    else if (cells[1] !== t.ko || cells[2] !== t.en) fails.push(`${path.basename(docFile)} §1.3 copy.${key}\n    want | ${t.ko} | ${t.en} |\n    got  | ${cells[1]} | ${cells[2]} |`);
  }
  n++;
  if (!doc.includes(`\`${fx.icon.symbol}\``) || !doc.includes(`\`${fx.icon.tint}\``)) fails.push(`${path.basename(docFile)}: the icon \`${fx.icon.symbol}\` · \`${fx.icon.tint}\` is not written`);
  n++;
  const sha = createHash('sha256').update(bytes).digest('hex');
  const size = `${bytes.length.toLocaleString('en-US')} 바이트`;
  if (!doc.includes(`sha256 \`${sha}\``) || !doc.includes(size)) fails.push(`${path.basename(docFile)} §7: write the vectors' bytes as sha256 \`${sha}\` · ${size}`);
  return { n, fails };
}

// MARK: - 올리기 전 검사

export function checkSiteFeed(file, today = localToday()) {
  const errors = [];
  const warnings = [];
  const bytes = fs.readFileSync(file);
  const r = parseFeed(bytes);
  if (!r.accepted) return { errors: [`앱이 이 파일 전체를 읽지 않아요: ${r.reason}`], warnings, items: [] };
  for (const d of r.dropped) errors.push(`items[${d.index}]${d.id ? ` (${d.id})` : ''} 을 앱이 버려요: ${d.reason}`);
  for (const id of r.linkRemoved) errors.push(`${id}: link 가 https://spiralday.com/… 이 아니라 앱이 링크를 빼요`);
  const text = bytes.toString('utf8').replace(/^\uFEFF/, '');
  const doc = JSON.parse(text);
  if (bytes[0] === 0xef) warnings.push('파일 맨 앞에 BOM 이 있어요 (앱은 읽지만 빼 주세요)');
  // 같은 객체에 같은 키가 두 번: 앱마다 다르게 읽을 수 있어 올리지 않는다 (앞의 값은 버려지거나 파일 전체를 버리게 한다)
  for (const k of new Set(duplicateKeys(text))) errors.push(`같은 키 "${k}" 가 한 객체 안에 두 번 있어요 — 하나만 남겨 주세요 (앱마다 다르게 읽을 수 있어요)`);
  for (const it of r.items) {
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}-/.test(it.id)) warnings.push(`${it.id}: id 는 날짜로 시작하게 (예: ${it.date}-sync-check)`);
    if (it.title.en === undefined || it.body.en === undefined) warnings.push(`${it.id}: 영어(en) 가 없어 영어로 쓰는 앱에도 한국어로 보여요`);
    if (it.importance === 'important' && it.expires === null) warnings.push(`${it.id}: important 에는 expires 를 꼭 적어 주세요 (새로 설치한 분께도 카드로 떠요)`);
    if (it.expires !== null && it.expires < it.date) errors.push(`${it.id}: expires 가 date 보다 앞이라 아무에게도 보이지 않아요`);
    if (it.date > today) warnings.push(`${it.id}: date 가 오늘(${today}) 뒤라 그날부터 보여요`);
    if (it.platforms) for (const p of it.platforms) if (!PLATFORMS.includes(p)) warnings.push(`${it.id}: 모르는 platforms 값 ${p} (앱은 무시해요)`);
  }
  const raw = Array.isArray(doc.items) ? doc.items : [];
  raw.forEach((x, i) => {
    if (!isObject(x)) return;
    const known = ['id', 'date', 'kind', 'importance', 'title', 'body', 'platforms', 'minVersion', 'maxVersion', 'syncOnly', 'link', 'expires'];
    for (const k of Object.keys(x)) if (!known.includes(k)) warnings.push(`items[${i}]: 앱이 모르는 필드 ${k} (무시해요)`);
  });
  return { errors, warnings, items: r.items };
}

function localToday() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function main(argv) {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const fixturesOnly = argv[0] === '--fixtures';
  const feedFile = !fixturesOnly && argv[0] ? path.resolve(argv[0]) : path.join(root, 'site/news/news.json');
  const fixtureFile = fixturesOnly && argv[1] ? path.resolve(argv[1]) : path.join(root, 'Tests/Fixtures/news-rules.json');
  let failed = false;
  if (!fixturesOnly) {
    const { errors, warnings, items } = checkSiteFeed(feedFile);
    for (const w of warnings) console.log(`  주의  ${w}`);
    for (const e of errors) console.log(`  오류  ${e}`);
    console.log(errors.length ? `✗ ${path.relative(root, feedFile)} — 고칠 곳 ${errors.length}개` : `✓ ${path.relative(root, feedFile)} — 항목 ${items.length}개, 앱이 모두 읽어요`);
    failed ||= errors.length > 0;
  }
  if (fixturesOnly || argv.length === 0) {
    const { n, fails } = runFixtures(fixtureFile);
    for (const f of fails) console.log(`  ✗ ${f}`);
    console.log(fails.length ? `✗ ${path.relative(root, fixtureFile)} — ${fails.length}/${n} 틀림` : `✓ ${path.relative(root, fixtureFile)} — ${n}개 모두 맞음`);
    failed ||= fails.length > 0;
    // 사양과 벡터가 같은 말을 하는지 (문구 표 · 아이콘 · 벡터의 바이트)
    const docFile = path.join(root, 'Docs/InAppNews.md');
    if (fs.existsSync(docFile)) {
      const spec = checkSpec(fixtureFile, docFile);
      for (const f of spec.fails) console.log(`  ✗ ${f}`);
      console.log(spec.fails.length ? `✗ ${path.relative(root, docFile)} — 벡터와 다른 곳 ${spec.fails.length}/${spec.n}` : `✓ ${path.relative(root, docFile)} — 문구 ${spec.n - 2}줄 · 아이콘 · 벡터의 바이트가 벡터와 같음`);
      failed ||= spec.fails.length > 0;
    }
  }
  process.exit(failed ? 1 : 0);
}

if (process.argv[1] && fs.realpathSync(path.resolve(process.argv[1])) === fs.realpathSync(fileURLToPath(import.meta.url))) main(process.argv.slice(2));
