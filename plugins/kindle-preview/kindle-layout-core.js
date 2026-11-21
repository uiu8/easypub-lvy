// 五组 Kindle 管线共用的浏览器断行内核。
// 该文件负责候选扫描、固件字符描述、行内间距和确定性的分页状态计算。
'use strict';

(function installKindleLayoutCore(global) {
  const CLOSING = '。，、；：？！」』）》】〉';
  const CLOSING_ALL = CLOSING + '”’';
  const QUOTES = '“”‘’';
  const OPENING = '“‘「『（《【〈';
  const FULL_MARKS = CLOSING + OPENING + QUOTES;
  const NO_END = new Set(['(', '/', '<', '[', '{', '‘', '“', '〈', '《', '「', '『', '【', '〔', '〖', '（', '［', '｛']);
  const NO_START = new Set(['!', ')', ',', '-', '.', '/', ':', ';', '>', '?', ']', '}', '~', '·', '–', '—', '’', '”', '•', '‧', '‼', '⁇', '、', '。', '〉', '》', '」', '』', '】', '〔', '〕', '〗', '！', '）', '，', '．', '／', '：', '；', '？', '］', '｝', '～']);

  const han = (c) => /[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]/u.test(c);
  const latin = (c) => /[A-Za-z0-9]/u.test(c);
  const cjk = (c) => han(c);
  const f32 = (n) => Math.fround(n);

  function profileFor(engine) {
    switch (engine) {
      case 'modern': return {
        id: 'modern', scored: true, tolerance: .001, ellipsisStart: true,
        orphans: 1, widows: 1, explicitPagination: true,
      };
      case 'kpw5': return {
        id: 'kpw5', scored: true, tolerance: .001, ellipsisStart: true,
        orphans: 1, widows: 1, explicitPagination: true,
      };
      case 'legacy-voyage': return {
        id: 'legacy-voyage', scored: false, tolerance: .001, ellipsisStart: false,
        orphans: 1, widows: 1, explicitPagination: true,
      };
      case 'legacy-kpw3': return {
        id: 'legacy-kpw3', scored: false, tolerance: .001, ellipsisStart: false,
        orphans: 1, widows: 1, explicitPagination: true,
      };
      default: return {
        id: 'legacy-kpw4', scored: false, tolerance: .001, ellipsisStart: false,
        orphans: 1, widows: 1, explicitPagination: true,
      };
    }
  }

  function descriptor(left, right) {
    if (cjk(left) && latin(right)) return [19, 2];
    if (latin(left) && cjk(right)) return [2, 19];
    if (left === '，' && (cjk(right) || OPENING.includes(right))) return [5, 2];
    if (left === '。' && cjk(right)) return [4, 2];
    if (left === '。' && right === '”') return [0, 0];
    if (left === '”' && right === '“') return [5, 2];
    if (left === '）' && right === '（') return [5, 2];
    if (left === '、' && right === '，') return [0, 0];
    if (CLOSING_ALL.includes(left) && (CLOSING_ALL.includes(right) || OPENING.includes(right))) return [0, 0];
    if (OPENING.includes(left) && OPENING.includes(right)) return [5, 2];
    if (NO_START.has(right) || NO_END.has(left)) return [0, 0];
    return [1, 1];
  }

  const DESCRIPTOR_SCORES = [-7, -6, -5.5, -5, -4.5, -4, -3.5, -3, -2.5, -2, -1, 0, 1, 2, 2.5, 3, 4, 7];
  const DESCRIPTOR_WIDTHS = [
    [0,0,0,0,0,0,0,0,0,0,0,0,0,0,.0625,.125,1.125,4.125],
    [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,4],
    [.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5],
    [.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,1.5,4.5],
    [0,0,0,0,.25,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,1.5,4.5],
    [0,0,0,0,.25,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5],
    [.25,.25,.25,.25,.25,.25,.375,.5,.5,.5,.5,.5,.5,.5,.5,.5,1.5,4.5],
    [.25,.25,.25,.25,.25,.25,.375,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5],
    [0,0,0,0,0,0,0,0,0,.5,.5,.5,.5,.5,.5,.5,.5,.5],
    [.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25],
    [0,0,0,0,0,0,0,0,.125,.25,.25,.25,.25,.25,.25,.25,.25,.25],
    [0,0,0,0,0,0,.125,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25],
    [0,0,0,0,0,0,.125,.25,.25,.25,.25,.25,.25,.25,.25,.25,1.25,4.25],
    [.125,.125,.1875,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25],
    [.125,.125,.1875,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.5,.5,.5,1.5,4.5],
    [.125,.125,.1875,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,1.25,4.25],
    [.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.5,.5,.5,1.5,4.5],
    [.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,1.25,4.25],
    [0,0,.0375,.075,.075,.075,.075,.075,.075,.075,.075,.075,.075,.075,.075,.075,1.075,4.075],
    [0,0,0,0,0,0,0,0,0,0,0,0,1,2,2.5,3,4,7],
    [.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,.25,1.25,2.25,2.75,3.25,4.25,7.25],
    [.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,.5,1.5,2.5,3,3.5,4.5,7.5],
    [0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1],
  ];

  function descriptorWidth(id, scale, q) {
    if (id < 1 || id > DESCRIPTOR_WIDTHS.length || !scale) return 0;
    const row = DESCRIPTOR_WIDTHS[id - 1];
    const value = f32(q);
    if (value <= DESCRIPTOR_SCORES[0]) return f32(scale * row[0]);
    let i = DESCRIPTOR_SCORES.length - 2;
    if (value < DESCRIPTOR_SCORES[DESCRIPTOR_SCORES.length - 1]) {
      for (let k = 0; k + 1 < DESCRIPTOR_SCORES.length; k++) {
        if (value <= DESCRIPTOR_SCORES[k + 1]) { i = k; break; }
      }
    }
    const span = DESCRIPTOR_SCORES[i + 1] - DESCRIPTOR_SCORES[i];
    const t = (value - DESCRIPTOR_SCORES[i]) / span;
    return f32(scale * (row[i] + (row[i + 1] - row[i]) * t));
  }

  function descriptorPairWidth(pair, previousScale, currentScale, q) {
    return f32(descriptorWidth(pair[0], previousScale, q) + descriptorWidth(pair[1], currentScale, q));
  }

  function descriptor19(em, q) { return descriptorWidth(19, em, q); }

  function candidateDescriptorScore(chars, start, end, em, q) {
    let score = 0;
    for (let i = start; i + 1 < end; i++) {
      score = f32(score + descriptorPairWidth(descriptor(chars[i], chars[i + 1]), em, em, q));
    }
    return score;
  }

  function layoutText(text, options) {
    const width = Math.max(1, Number(options.width) || 1);
    const em = Math.max(.01, Number(options.em) || 1);
    const indent = Math.max(0, Number(options.indent) || 0);
    // 浏览器的 letter-spacing 不会进入 canvas.measureText。把书内字距放进
    // 候选宽度，保证生成的 .ep-line 与实际绘制仍使用同一条固件链。
    const tracking = Number(options.tracking) || 0;
    const justify = options.justify !== false;
    const profile = profileFor(options.engine);
    const advance = options.advance || (() => em);
    const chars = Array.from(text);
    if (!chars.length) return [];
    const n = chars.length;
    const drawn = chars.map((ch, index) => Number(advance(ch, index)) || 0);
    const quote = chars.map((ch) => QUOTES.includes(ch));
    const naturalBase = chars.map((ch, i) => {
      const advance = FULL_MARKS.includes(ch) || quote[i] ? em : drawn[i];
      return advance;
    });
    const base = naturalBase.map((value, i) => value + (i + 1 < n ? tracking : 0));
    const full = chars.map((ch, i) => FULL_MARKS.includes(ch) || quote[i] || naturalBase[i] >= em * .9);
    const closing = chars.map((ch) => CLOSING_ALL.includes(ch));
    const adjust = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      const next = chars[i + 1];
      if (!next) continue;
      const pair = descriptor(chars[i], next);
      if (closing[i] && full[i] && pair[0] === 0 && pair[1] === 0
        && (CLOSING_ALL.includes(next) || OPENING.includes(next))) adjust[i] -= em / 2;
      if (OPENING.includes(next) && full[i] && (chars[i] === '　' || OPENING.includes(chars[i]))) adjust[i] -= em / 2;
      if ((pair[0] === 19 && pair[1] === 2) || (pair[0] === 2 && pair[1] === 19)) adjust[i] += descriptor19(em, 0);
    }
    const endCut = (i) => closing[i] && full[i] && adjust[i] >= 0 ? em / 2 : 0;
    const breakable = (i) => {
      if (i <= 0 || i >= n) return true;
      const a = chars[i - 1];
      const b = chars[i];
      if (NO_START.has(b) || NO_END.has(a)) return false;
      if (a === b && (a === '—' || a === '…')) return false;
      if (!profile.ellipsisStart && b === '…') return false;
      if (latin(a) && latin(b)) return false;
      return true;
    };
    const lines = [];
    let start = 0;
    let first = true;
    while (start < n) {
      const avail = Math.max(em, width - (first ? indent : 0));
      let used = 0;
      let best = -1;
      let bestDistance = Infinity;
      let i = start;
      for (; i < n; i++) {
        used += base[i] + adjust[i];
        const natural = used - endCut(i) - (adjust[i] > 0 ? adjust[i] : 0);
        const natural32 = f32(natural);
        if (natural32 - f32(avail) >= profile.tolerance) break;
        const end = i + 1;
        if (end !== n && !breakable(end)) continue;
        if (!profile.scored) {
          best = end;
          continue;
        }
        const q = em ? f32((avail - natural32) / em) : 0;
        const score = candidateDescriptorScore(chars, start, end, em, q);
        const distance = f32(Math.abs(avail - natural32) + Math.abs(score) * 1e-6);
        if (distance <= bestDistance + 1e-7) {
          best = end;
          bestDistance = distance;
        }
      }
      if (best <= start) best = Math.max(start + 1, i);
      const count = best - start;
      const spacing = adjust.slice(start, best);
      spacing[count - 1] -= endCut(best - 1);
      if (adjust[best - 1] > 0) spacing[count - 1] -= adjust[best - 1];
      if (justify && best < n && count > 1) {
        let natural = 0;
        for (let k = 0; k < count; k++) natural += base[start + k] + spacing[k];
        const extra = avail - natural;
        if (extra > 0) {
          const each = extra / (count - 1);
          for (let k = 0; k < count - 1; k++) spacing[k] += each;
        }
      }
      for (let k = 0; k < count; k++) if (quote[start + k]) spacing[k] += em - drawn[start + k];
      lines.push({ start, end: best, text: chars.slice(start, best).join(''), spacing });
      start = best;
      first = false;
    }
    return lines;
  }

  function paginateLines(paragraphs, options = {}) {
    const height = Math.max(Number(options.height) || 1, 1);
    const lineHeight = Math.max(Number(options.lineHeight) || 1, .001);
    const valueAt = (value, index, fallback) => {
      const raw = Array.isArray(value) ? value[index] : value;
      const number = Math.trunc(Number(raw));
      return Math.max(1, Math.min(15, Number.isFinite(number) && number > 0 ? number : fallback));
    };
    const before = options.breakBefore || [];
    const after = options.breakAfter || [];
    const keep = options.keepWithNext || [];
    const spacingAt = (index) => {
      const raw = Array.isArray(options.paragraphSpacing)
        ? options.paragraphSpacing[index]
        : options.paragraphSpacing;
      const number = Number(raw);
      return Number.isFinite(number) && number > 0 ? number : 0;
    };
    const pages = [];
    let page = [];
    let used = 0;
    const flush = () => {
      if (page.length) pages.push(page), page = [], used = 0;
    };
    const capacity = (paragraphGap) => Math.max(
      0,
      Math.floor((height - used - Math.max(0, Number(paragraphGap) || 0)) / lineHeight),
    );
    for (let p = 0; p < paragraphs.length; p++) {
      const count = paragraphs[p] || 0;
      if (!count) continue;
      if (before[p]) flush();
      if (p > 0 && keep[p - 1] && page.length && capacity(spacingAt(p)) < count) flush();
      let offset = 0;
      while (offset < count) {
        const orphan = valueAt(options.orphans, p, 1);
        const widow = valueAt(options.widows, p, 1);
        const paragraphGap = spacingAt(p);
        let room = capacity(page.length > 0 ? paragraphGap : 0);
        if (room < Math.min(orphan, count - offset)) flush(), room = capacity(0);
        if (room <= 0) flush(), room = capacity(0);
        const remaining = count - offset;
        let take = Math.min(room, remaining);
        if (take < remaining && remaining - take < widow) {
          const reduced = remaining - widow;
          if (reduced >= Math.min(orphan, remaining) && reduced > 0) take = reduced;
          else { flush(); continue; }
        }
        if (page.length && paragraphGap > 0) used += paragraphGap;
        for (let line = 0; line < take; line++) page.push({ paragraph: p, line: offset + line });
        used += take * lineHeight;
        offset += take;
        if (offset < count) flush();
      }
      if (after[p]) flush();
    }
    flush();
    return pages;
  }

  global.EasyPubKindleLayout = {
    layoutText, paginateLines, profileFor, descriptor, descriptorWidth, descriptorPairWidth,
  };
})(window);

