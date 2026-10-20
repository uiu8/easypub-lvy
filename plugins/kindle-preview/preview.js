// 真机预览（EasyPub++ V30，LAY-108–110；V36 起每章一个文件，按 spine 跨文件翻页）。由排版页通过本机连接提供数据：
//   GET  api/state    书名、机型、阅读器设置、当前排版值、当前章节
//   POST api/render   {values, entry} → 按这些排版值生成本书内容（不保存）
//   POST api/metrics  {device, level, margin, spacing, values} → 阅读器字号、行高、页边距
//   POST api/apply    {values} → 写回本书
'use strict';

const BOOK_KEYS = ['writing_mode', 'vertical_digits', 'font_size', 'line_height',
  'fullwidth_indent', 'paragraph_spacing', 'text_alignment', 'heading_style', 'scene_break_style', 'first_paragraph_style', 'chapter_head_scope', 'chapter_head_width', 'system_block_style', 'verse_block_style', 'note_style',
  // V76：生僻字注音；章节样式包的开关与卷页边框（只在本书用了样式包时出现）。
  'rare_char_ruby', 'rare_char_scope', 'chapter_style_on', 'chapter_style_volume_frame',
  // V77：系统提示分类样式的两个预设（参数改过时为 custom）。
  'system_note_preset', 'system_panel_preset',
  // V81：场景样式（聊天记录自动识别与样式、书信样式、场景字体）。
  'chat_block_style', 'letter_block_style', 'inset_font',
  // V82：场景识别（诏书、论坛楼层与自定义规则）。
  'inset_detect'];
const NUMBER_KEYS = { font_size: 'float', line_height: 'float', fullwidth_indent: 'int', paragraph_spacing: 'float' };
const FONTS = {
  publisher: '',
  song: '"SimSun", "NSimSun", "Songti SC", serif',
  hei: '"Microsoft YaHei", "SimHei", sans-serif',
  kai: '"KaiTi", "STKaiti", serif',
  yuan: '"YouYuan", "Microsoft YaHei", sans-serif',
};
const GAP = 48;

const $ = (id) => document.getElementById(id);
const frame = $('book');
const S = {
  devices: [], device: null, reader: { level: 8, margin: 'narrow', spacing: 'medium', font: 'publisher' },
  saved: {}, draft: {}, metrics: null, render: null, title: '',
  page: 0, pages: 1, vertical: false, headings: [], entry: null, seq: 0, timer: 0,
  // 每章一个文件（V36，OUT-081）：spine 为阅读顺序中的文件，doc 为当前文件，chapters 为章节列表。
  spine: [], doc: '', chapters: [], tocChapters: false,
};

async function api(name, body) {
  const init = body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  };
  let response;
  try {
    response = await fetch('api/' + name, init);
  } catch (error) {
    gone();
    throw error;
  }
  if (!response.ok) {
    if (response.status === 403) gone();
    throw new Error('HTTP ' + response.status);
  }
  return response.json();
}

function gone() { $('gone').hidden = false; }

function status(text, error) {
  const el = $('status');
  el.textContent = text || '';
  el.classList.toggle('error', !!error);
}

function pick(values) {
  const out = {};
  for (const key of BOOK_KEYS) if (values[key] !== undefined) out[key] = values[key];
  return out;
}

function dirtyKeys() {
  return BOOK_KEYS.filter((key) => String(S.draft[key]) !== String(S.saved[key]));
}

// ---------------------------------------------------------------- 机身

function drawDevice() {
  const d = S.device;
  if (!d) return;
  const stage = $('stage');
  const availW = stage.clientWidth - 40;
  const availH = stage.clientHeight - 90;
  const s = Math.max(0.5, Math.min(availW / d.bodyWidthMm, availH / d.bodyHeightMm));
  const screenW = d.width / d.ppi * 25.4;
  const screenH = d.height / d.ppi * 25.4;
  const body = $('device-body');
  body.style.width = d.bodyWidthMm * s + 'px';
  body.style.height = d.bodyHeightMm * s + 'px';
  body.style.borderRadius = (d.cornerMm || 6) * s + 'px';
  // 侧边轮廓：Oasis、Scribe 为浅灰金属边，其他为略浅于正面的深灰（V31，按实拍照片）。
  body.style.setProperty('--rim', Math.max(1.2, 0.8 * s) + 'px');
  body.classList.toggle('metal', !!d.grip);
  // 上边框按实拍测量（握持机型为三条窄边）；Oasis 宽边在右、Scribe 在左；其他机型左右居中、下边框取余量。
  const top = d.topBezelMm || 10;
  const left = d.grip
    ? (d.gripLeft ? d.bodyWidthMm - top - screenW : top)
    : (d.bodyWidthMm - screenW) / 2;
  const screen = $('screen');
  screen.style.left = left * s + 'px';
  screen.style.top = top * s + 'px';
  screen.style.width = screenW * s + 'px';
  screen.style.height = screenH * s + 'px';
  const viewport = $('viewport');
  viewport.style.width = d.viewportWidth + 'px';
  viewport.style.height = d.viewportHeight + 'px';
  viewport.style.transform = 'scale(' + (screenW * s / d.viewportWidth) + ')';
  // Oasis 握持宽边上的两个翻页键（中心约在机身高度 40%、56%）。
  const buttons = $('grip-buttons');
  const oasis = d.grip && d.id.startsWith('oasis');
  buttons.hidden = !oasis;
  if (oasis) {
    const gripW = d.bodyWidthMm - top - screenW;
    [...buttons.children].forEach((b, i) => {
      b.style.left = (top + screenW + gripW * 0.39) * s + 'px';
      b.style.width = gripW * 0.22 * s + 'px';
      b.style.top = d.bodyHeightMm * (0.40 + i * 0.16 - 0.0425) * s + 'px';
      b.style.height = d.bodyHeightMm * 0.085 * s + 'px';
    });
  }
  // 下边框中间的“kindle”字样（约在下边框 45% 高度处）。
  const logo = $('logo');
  logo.hidden = !d.logo;
  if (d.logo) {
    const bottom = d.bodyHeightMm - top - screenH;
    logo.className = d.logo;
    logo.style.top = (top + screenH + bottom * 0.45) * s + 'px';
    logo.style.fontSize = 4.4 * s + 'px';
  }
  // Voyage 两侧的压感翻页标记：上方一个点、中部一条短竖线。
  const marks = $('press-marks');
  marks.hidden = !d.pressMarks;
  if (d.pressMarks) {
    const side = (d.bodyWidthMm - screenW) / 2;
    [...marks.children].forEach((m, i) => {
      const x = (i % 2 ? d.bodyWidthMm - side / 2 : side / 2) * s;
      const line = i >= 2;
      m.style.left = x - (line ? 0.25 : 0.6) * s + 'px';
      m.style.width = (line ? 0.5 : 1.2) * s + 'px';
      m.style.top = d.bodyHeightMm * (line ? 0.47 : 0.33) * s + 'px';
      m.style.height = (line ? d.bodyHeightMm * 0.09 : 1.2) * s + 'px';
    });
  }
  $('dims').textContent = '机身 ' + d.bodyWidthMm + ' × ' + d.bodyHeightMm + ' mm · 屏幕 '
    + screenW.toFixed(1) + ' × ' + screenH.toFixed(1) + ' mm · 按比例缩放到窗口';
}

// ---------------------------------------------------------------- 分页

// Kindle 中文排版（V34，LAY-115，按用户 KPW5 与预览并排照片核对）：
// · 行末的句号、逗号等后置标点压成半个字宽：标点半宽，后面跟一个半宽空格；行中两者合起来仍是一个字宽，
//   行末的空格由浏览器去掉，所以只在行末变成半宽（Edge 不支持 text-spacing-trim 的行末挤压与 hanging-punctuation）；
// · 横排时弯引号“”‘’用西文字体，约 0.38 个字宽（真机如此）。
const CLOSING = '。，、；：」』）》】〉';
const QUOTES = '“”‘’';
const XHTML = 'http://www.w3.org/1999/xhtml';
function kindleTypography(doc) {
  if (doc.__easypubTypography || !doc.body) return;
  doc.__easypubTypography = true;
  const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.parentElement && n.parentElement.closest('rt,rp,script,style'))
      ? NodeFilter.FILTER_REJECT
      : [...n.data].some((c) => CLOSING.includes(c) || QUOTES.includes(c))
        ? NodeFilter.FILTER_ACCEPT
        : NodeFilter.FILTER_SKIP,
  });
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  const span = (cls, text) => {
    const s = doc.createElementNS(XHTML, 'span');
    s.setAttribute('class', cls);
    s.textContent = text;
    return s;
  };
  for (const node of nodes) {
    const frag = doc.createDocumentFragment();
    let plain = '';
    const flush = () => {
      if (plain) frag.appendChild(doc.createTextNode(plain));
      plain = '';
    };
    for (const ch of node.data) {
      if (CLOSING.includes(ch)) {
        flush();
        frag.appendChild(span('ep-p', ch));
        frag.appendChild(span('ep-s', ' '));
      } else if (QUOTES.includes(ch)) {
        flush();
        frag.appendChild(span('ep-q', ch));
      } else {
        plain += ch;
      }
    }
    flush();
    node.replaceWith(frag);
  }
}

// 半宽空格：按当前正文字体量出空格宽度，word-spacing 补到半个字宽。
function setHalfSpace(doc, vertical) {
  const probe = doc.createElementNS(XHTML, 'span');
  probe.style.whiteSpace = 'pre';
  probe.textContent = ' ';
  (doc.querySelector('p') || doc.body).appendChild(probe);
  const box = probe.getBoundingClientRect();
  const ratio = (vertical ? box.height : box.width) / parseFloat(getComputedStyle(probe).fontSize);
  probe.remove();
  doc.documentElement.style.setProperty('--ep-ws', (0.5 - ratio).toFixed(4) + 'em');
}

// 书内“另起一页”（V33，LAY-114）：浏览器按列分页时只认换栏，不认换页。
// 先从样式表找出写了换页的选择器（含行内样式），再按每个元素实际生效的样式判断（层叠后可能被取消，
// 如 content-continuation），确实换页的元素改为换栏——章节、书名页、目录页才会像 Kindle 一样另起一页。
const PAGE_BREAK = /^(page|left|right|recto|verso|always)$/;
// 字号关键字（V36，LAY-117）：浏览器按自身默认字号解释 x-large 等关键字，不随预览设置的阅读器字号变化；
// Kindle 与 Bokai 按阅读器基准字号换算（x-large 为 1.5 倍）。改写成 rem 后与真机比例一致（EasyPub 经典标题用 x-large）。
const KEYWORD_SIZES = {
  'xx-small': 0.5625, 'x-small': 0.625, small: 0.8125, medium: 1,
  large: 1.125, 'x-large': 1.5, 'xx-large': 2, 'xxx-large': 3,
};
function keywordFontSizes(doc) {
  if (doc.__easypubKeywordSizes) return;
  doc.__easypubKeywordSizes = true;
  const visit = (rules) => {
    for (const rule of rules) {
      if (rule.cssRules && !rule.style) {
        visit(rule.cssRules);
        continue;
      }
      const size = rule.style && rule.style.getPropertyValue('font-size').trim().toLowerCase();
      if (size && KEYWORD_SIZES[size] !== undefined) {
        rule.style.setProperty('font-size', KEYWORD_SIZES[size] + 'rem', rule.style.getPropertyPriority('font-size'));
      }
    }
  };
  for (const sheet of doc.styleSheets) {
    try {
      visit(sheet.cssRules);
    } catch (_) { /* 读不到的样式表跳过 */ }
  }
}

function markPageBreaks(doc) {
  if (doc.__easypubBreaks) return doc.__easypubBreaks;
  const selectors = new Set(['[style*="break"]']);
  const visit = (rules) => {
    for (const rule of rules) {
      if (rule.cssRules && !rule.style) {
        visit(rule.cssRules);
        continue;
      }
      if (!rule.style || !rule.selectorText) continue;
      const s = rule.style;
      if (['break-before', 'page-break-before', 'break-after', 'page-break-after']
        .some((p) => PAGE_BREAK.test(s.getPropertyValue(p).trim()))) selectors.add(rule.selectorText);
    }
  };
  for (const sheet of doc.styleSheets) {
    try {
      visit(sheet.cssRules);
    } catch (_) { /* 读不到的样式表跳过 */ }
  }
  let count = 0;
  for (const selector of selectors) {
    let elements = [];
    try {
      elements = doc.querySelectorAll(selector);
    } catch (_) { /* 浏览器不认识的选择器跳过 */ }
    for (const el of elements) {
      const style = getComputedStyle(el);
      if (PAGE_BREAK.test(style.breakBefore)) {
        el.style.setProperty('break-before', 'column', 'important');
        count++;
      }
      if (PAGE_BREAK.test(style.breakAfter)) {
        el.style.setProperty('break-after', 'column', 'important');
        count++;
      }
    }
  }
  doc.__easypubBreaks = { count };
  return doc.__easypubBreaks;
}

function area() {
  const d = S.device;
  const p = S.metrics.padding;
  return {
    left: p.left, top: p.top,
    width: Math.floor(d.viewportWidth - p.left - p.right),
    height: Math.floor(d.viewportHeight - p.top - p.bottom),
  };
}

function layout(keepRatio) {
  const doc = frame.contentDocument;
  if (!doc || !doc.documentElement || !S.metrics) return;
  const a = area();
  Object.assign(frame.style, { left: a.left + 'px', top: a.top + 'px', width: a.width + 'px', height: a.height + 'px' });
  Object.assign($('page-head').style, { top: '0px', height: a.top + 'px' });
  Object.assign($('page-foot').style, {
    bottom: '0px', height: (S.device.viewportHeight - a.top - a.height) + 'px',
    paddingLeft: a.left + 'px', paddingRight: a.left + 'px',
  });
  let style = doc.getElementById('easypub-reader');
  if (!style) {
    style = doc.createElementNS('http://www.w3.org/1999/xhtml', 'style');
    style.id = 'easypub-reader';
    (doc.head || doc.documentElement).appendChild(style);
  }
  const vertical = getComputedStyle(doc.documentElement).writingMode.startsWith('vertical');
  S.vertical = vertical;
  const m = S.metrics;
  const font = FONTS[S.reader.font];
  markPageBreaks(doc);
  keywordFontSizes(doc);
  kindleTypography(doc);
  // 正文按列分页：横排的列向右排、竖排的列向下排；每页一列。
  style.textContent = [
    'html{color:#1E1E1E;font-size:' + m.rootPx + 'px!important;margin:0!important;padding:0!important;overflow:hidden!important;'
      + 'background:transparent!important;width:' + a.width + 'px!important;height:' + a.height + 'px!important}',
    'body{margin:0!important;padding:0!important;background:transparent!important;column-gap:' + GAP + 'px!important;'
      + 'column-fill:auto!important;' + (vertical
        ? 'width:' + a.width + 'px!important;height:auto!important;column-width:' + a.height + 'px!important}'
        : 'height:' + a.height + 'px!important;width:auto!important;column-width:' + a.width + 'px!important}'),
    'body *:not(rt){line-height:' + m.lineRatio + '!important}',
    'img,svg{max-width:100%!important;max-height:' + a.height + 'px!important}',
    font ? 'body,body *:not(rt){font-family:' + font + '!important}' : '',
    // 用负字距而不是负外边距：负外边距加行末空格时，浏览器断行仍按整字宽计算。
    'html .ep-p{letter-spacing:-0.5em!important}',
    'html .ep-s{word-spacing:var(--ep-ws,0)!important}',
    vertical ? '' : 'html .ep-q{font-family:"Segoe UI",Arial,sans-serif!important}',
  ].join('\n');
  setHalfSpace(doc, vertical);
  const root = doc.scrollingElement || doc.documentElement;
  const step = vertical ? a.height + GAP : a.width + GAP;
  const extent = vertical ? root.scrollHeight : root.scrollWidth;
  S.pages = Math.max(1, Math.round((extent + GAP) / step));
  S.headings = [...doc.querySelectorAll('h1[id^="node-"],h2[id^="node-"],h3[id^="node-"],h4[id^="node-"]')]
    .map((el) => ({ id: el.id, page: pageOf(el), text: el.textContent.trim(), level: Number(el.tagName[1]) }));
  // 书里没有可用的目录时，章节列表只列当前文件中的标题。
  if (!S.tocChapters) {
    S.chapters = S.headings.map((h) => ({ href: S.doc + '#' + h.id, text: h.text, level: h.level }));
    fillChapters();
  }
  if (keepRatio !== undefined) S.page = Math.round(keepRatio * (S.pages - 1));
  show(S.page);
}

function pageOf(el) {
  const doc = frame.contentDocument;
  const root = doc.scrollingElement || doc.documentElement;
  const a = area();
  const rect = el.getBoundingClientRect();
  return S.vertical
    ? Math.max(0, Math.floor((rect.top + root.scrollTop) / (a.height + GAP)))
    : Math.max(0, Math.floor((rect.left + root.scrollLeft) / (a.width + GAP)));
}

function show(page) {
  const doc = frame.contentDocument;
  if (!doc) return;
  S.page = Math.max(0, Math.min(S.pages - 1, page));
  const root = doc.scrollingElement || doc.documentElement;
  const a = area();
  if (S.vertical) root.scrollTop = S.page * (a.height + GAP);
  else root.scrollLeft = S.page * (a.width + GAP);
  $('page-no').textContent = '第 ' + (S.page + 1) + ' 页';
  // 进度按全书文件顺序估算：前面的文件加上本文件已读的比例。
  const index = S.spine.indexOf(S.doc);
  const done = index >= 0
    ? (index + (S.page + 1) / S.pages) / S.spine.length
    : (S.page + 1) / S.pages;
  $('progress').textContent = Math.round(done * 100) + '%';
  const current = S.headings.filter((h) => h.page <= S.page).pop();
  if (current) {
    $('chapter').value = S.doc + '#' + current.id;
  } else if (S.chapters.some((c) => c.href === S.doc)) {
    // 整个文件就是一条目录项（前后附页）。
    $('chapter').value = S.doc;
  } else if (index >= 0) {
    // 本文件开头没有章标题（如正文前的引言）：取前面文件里最后一章。
    const before = S.chapters.filter((c) => {
      const i = S.spine.indexOf(c.href.split('#')[0]);
      return i >= 0 && i < index;
    }).pop();
    if (before) $('chapter').value = before.href;
  }
  $('hint').textContent = '本章 ' + S.pages + ' 页 · '
    + (S.vertical ? '竖排：← 或点屏幕左侧翻到下一页' : '→ 或点屏幕右侧翻到下一页');
}

// 本文件翻完后接着翻到阅读顺序中的下一个文件（每章一个文件，V36）。
function turn(forward) {
  closeNote();
  const next = S.page + (forward ? 1 : -1);
  if (next >= 0 && next < S.pages) {
    show(next);
    return;
  }
  const index = S.spine.indexOf(S.doc);
  const target = index < 0 ? -1 : index + (forward ? 1 : -1);
  if (target >= 0 && target < S.spine.length) openDoc(S.spine[target], forward ? { page: 0 } : { last: true });
}
function side(left) { turn(S.vertical ? left : !left); }

function fillChapters() {
  const select = $('chapter');
  select.textContent = '';
  for (const c of S.chapters) {
    const option = document.createElement('option');
    option.value = c.href;
    option.textContent = '　'.repeat(Math.max(0, c.level - 1)) + c.text;
    select.appendChild(option);
  }
}

// 读出阅读顺序（package.opf 的 spine）与目录（nav.xhtml）。目录里有指向正文标题的链接时，
// 章节列表跨文件列出全书各章；否则只列当前文件中的标题。
async function loadSpine(base) {
  const parse = async (path, type) =>
    new DOMParser().parseFromString(await (await fetch(base + path)).text(), type);
  const spine = [];
  const chapters = [];
  try {
    const opf = await parse('package.opf', 'application/xml');
    const items = [...opf.getElementsByTagNameNS('*', 'item')];
    const hrefs = Object.fromEntries(items.map((i) => [i.getAttribute('id'), i.getAttribute('href')]));
    for (const ref of opf.getElementsByTagNameNS('*', 'itemref')) {
      const href = hrefs[ref.getAttribute('idref')];
      if (href) spine.push(href);
    }
    const nav = items.find((i) => (i.getAttribute('properties') || '').split(' ').includes('nav'));
    if (nav) {
      const doc = await parse(nav.getAttribute('href'), 'application/xhtml+xml');
      // 只取目录（epub:type="toc"），不取地标导航里的“封面 / 正文”等链接。
      const navs = [...doc.getElementsByTagNameNS(XHTML, 'nav')];
      const toc = navs.find((n) => /(^|\s)toc(\s|$)/.test(epubType(n))) || navs[0] || doc;
      for (const a of toc.getElementsByTagNameNS(XHTML, 'a')) {
        const href = a.getAttribute('href') || '';
        // 前后附页（V55）在目录里链接整个文件，不带锚点，也列出来。
        if (!spine.includes(href.split('#')[0])) continue;
        let level = 0;
        for (let n = a.parentNode; n; n = n.parentNode) if (n.localName === 'ol') level++;
        chapters.push({ href, text: a.textContent.trim(), level });
      }
    }
  } catch (_) { /* 读不到时按单个文件预览 */ }
  S.spine = spine;
  S.tocChapters = chapters.length > 0;
  if (S.tocChapters) {
    S.chapters = chapters;
    fillChapters();
  }
}

// ---------------------------------------------------------------- 书内链接与注释弹窗（V61）
// Kindle 点注释标记弹出注释，点目录、上一章 / 下一章等链接在书内跳转。浏览器默认会让 iframe 直接
// 跳到目标文件，打乱分页，所以书内链接一律由这里接管；外部链接不打开。
const OPS = 'http://www.idpf.org/2007/ops';
function epubType(el) {
  if (!el || el.nodeType !== 1) return '';
  return (el.getAttributeNS && el.getAttributeNS(OPS, 'type')) || el.getAttribute('epub:type') || '';
}
// 目标元素所在的注释（aside / div 上的 epub:type="footnote" 等）。
function footnoteOf(el) {
  for (let n = el; n && n.nodeType === 1; n = n.parentNode) {
    if (/(^|\s)(footnote|endnote|rearnote|note)(\s|$)/.test(epubType(n))) return n;
  }
  return null;
}
function closeNote() {
  $('note-pop').hidden = true;
  $('screen').classList.remove('noting');
}
function showNote(note) {
  const body = $('note-body');
  body.textContent = '';
  for (const child of note.childNodes) {
    const copy = document.importNode(child, true);
    if (copy.nodeType === 1) {
      copy.removeAttribute('id');
      for (const el of copy.querySelectorAll('[id]')) el.removeAttribute('id');
    }
    body.appendChild(copy);
  }
  const pop = $('note-pop');
  pop.style.fontSize = (S.metrics ? S.metrics.rootPx : 16) + 'px';
  pop.hidden = false;
  $('screen').classList.add('noting');
}
async function followLink(a) {
  const href = a.getAttribute('href') || '';
  if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href)) return;
  const [path, id] = href.split('#');
  const file = path ? new URL(path, 'http://book/' + S.doc).pathname.slice(1) : S.doc;
  closeNote();
  let doc = file === S.doc ? frame.contentDocument : null;
  let target = doc && id ? doc.getElementById(id) : null;
  const noteref = /(^|\s)noteref(\s|$)/.test(epubType(a));
  if (!doc && id && noteref) {
    try {
      const text = await (await fetch(S.render.base + file)).text();
      doc = new DOMParser().parseFromString(text, 'application/xhtml+xml');
      target = doc.getElementById(id);
    } catch (_) { target = null; }
  }
  const note = target ? footnoteOf(target) : null;
  if (note && (noteref || file === S.doc)) {
    showNote(note);
    return;
  }
  if (file === S.doc) {
    if (target) show(pageOf(target));
  } else if (S.spine.includes(file)) {
    openDoc(file, id ? { anchor: id } : { page: 0 });
  }
}
// 点在两侧翻页区时，若下面是链接（注释标记、目录项），按链接处理，不翻页。
function linkAt(event) {
  const doc = frame.contentDocument;
  if (!doc) return null;
  const rect = frame.getBoundingClientRect();
  const scale = rect.width / frame.offsetWidth || 1;
  const x = (event.clientX - rect.left) / scale;
  const y = (event.clientY - rect.top) / scale;
  if (x < 0 || y < 0 || x > frame.offsetWidth || y > frame.offsetHeight) return null;
  const el = doc.elementFromPoint(x, y);
  return el && el.closest ? el.closest('a[href]') : null;
}

// 打开阅读顺序中的另一个文件：where 为 {anchor} 跳到标题、{last} 翻到最后一页、{page} 指定页、{ratio} 保持比例。
function openDoc(file, where) {
  const seq = ++S.seq;
  S.doc = file;
  closeNote();
  frame.onload = () => {
    if (seq !== S.seq) return;
    const doc = frame.contentDocument;
    doc.addEventListener('keydown', keys);
    doc.addEventListener('click', (event) => {
      const a = event.target && event.target.closest ? event.target.closest('a[href]') : null;
      if (!a) return;
      event.preventDefault();
      followLink(a);
    });
    layout();
    const target = where.anchor ? doc.getElementById(where.anchor) : null;
    if (target) show(pageOf(target));
    else if (where.last) show(S.pages - 1);
    else if (where.ratio !== undefined) layout(where.ratio);
    else show(where.page || 0);
    status(dirtyKeys().length ? '预览中（未写回）' : '');
  };
  frame.src = S.render.base + file;
}

// ---------------------------------------------------------------- 生成与参数

async function refreshMetrics() {
  const d = S.device;
  S.metrics = await api('metrics', {
    device: d.id, level: S.reader.level, margin: S.reader.margin, spacing: S.reader.spacing,
    serif: S.reader.font === 'song' || S.reader.font === 'kai', values: S.draft,
  });
  $('measure').textContent = S.metrics.note;
  $('measure').title = S.metrics.measured ? '与真机照片或校准一致' : '只有 KPW5 的 4、8、12 档是实测，其余按 Kindle 固件的字号表与页边距推算';
  $('level').textContent = S.reader.level;
}

async function rerender(entry) {
  const seq = ++S.seq;
  const ratio = S.pages > 1 ? S.page / (S.pages - 1) : 0;
  status('正在生成…');
  const r = await api('render', { values: S.draft, entry: entry || undefined });
  if (seq !== S.seq) return;
  if (!r.ok) { status(r.message, true); return; }
  S.render = r;
  S.title = r.title || S.title;
  document.title = '真机预览 · ' + S.title;
  $('book-title').textContent = '真机预览 · ' + S.title;
  const previous = S.doc;
  await loadSpine(r.base);
  if (seq !== S.seq) return;
  // 改排版后留在正在看的这一章（文件名不随排版值变化）；指定了章节时跳到该章。
  if (!entry && previous && S.spine.includes(previous)) openDoc(previous, { ratio });
  else openDoc(r.content, entry && r.anchor ? { anchor: r.anchor } : { ratio });
}

function scheduleRender() {
  clearTimeout(S.timer);
  S.timer = setTimeout(async () => {
    try {
      await refreshMetrics();
      await rerender();
    } catch (_) { /* 连接断开时已提示 */ }
  }, 450);
}

// ---------------------------------------------------------------- 侧边栏

function buildSeg(el, onPick) {
  el.textContent = '';
  for (const pair of el.dataset.options.split(',')) {
    const [value, label] = pair.split(':');
    const b = document.createElement('button');
    b.type = 'button';
    b.dataset.value = value;
    b.textContent = label;
    b.addEventListener('click', () => { if (el.getAttribute('aria-disabled') !== 'true') onPick(value); });
    el.appendChild(b);
  }
}

function syncControls() {
  const dirty = new Set(dirtyKeys());
  for (const el of document.querySelectorAll('.seg[data-key]')) {
    const key = el.dataset.key;
    for (const b of el.children) b.classList.toggle('on', b.dataset.value === String(S.draft[key]));
    el.classList.toggle('changed', dirty.has(key));
  }
  $('aside-digits').setAttribute('aria-disabled', S.draft.writing_mode === 'vertical' ? 'false' : 'true');
  for (const input of document.querySelectorAll('input[data-key]')) {
    const key = input.dataset.key;
    if (document.activeElement !== input) input.value = S.draft[key];
    input.parentElement.classList.toggle('changed', dirty.has(key));
  }
  for (const el of document.querySelectorAll('.seg[data-reader]')) {
    for (const b of el.children) b.classList.toggle('on', b.dataset.value === S.reader[el.dataset.reader]);
  }
  // 章节标题样式（V36，LAY-117）。
  for (const el of document.querySelectorAll('select[data-key]')) {
    const key = el.dataset.key;
    el.value = S.draft[key] || 'classic';
    el.classList.toggle('changed', dirty.has(key));
  }
  $('font').value = S.reader.font;
  $('dirty').textContent = dirty.size ? dirty.size + ' 项未写回' : '';
  $('apply').disabled = dirty.size === 0;
  $('revert').disabled = dirty.size === 0;
}

// 章节样式包（V76）：显示包名；没用样式包时整组隐藏。
function showStyle(state) {
  $('chapter-style').hidden = !state.chapter_style_name;
  $('chapter-style-name').textContent = state.chapter_style_name || '';
}

// 分类样式时才显示两个预设（V77）。
function showSystem() {
  $('system-presets').hidden = S.draft.system_block_style !== 'styled';
}

function setDraft(key, value) {
  S.draft[key] = value;
  showSystem();
  syncControls();
  scheduleRender();
}

function setupControls() {
  for (const el of document.querySelectorAll('.seg[data-key]')) {
    if (el.dataset.key === 'vertical_digits') el.id = 'aside-digits';
    buildSeg(el, (value) => setDraft(el.dataset.key, el.dataset.number ? Number(value) : value));
  }
  for (const el of document.querySelectorAll('.seg[data-reader]')) {
    buildSeg(el, async (value) => {
      S.reader[el.dataset.reader] = value;
      syncControls();
      await refreshMetrics();
      layout(S.pages > 1 ? S.page / (S.pages - 1) : 0);
    });
  }
  for (const input of document.querySelectorAll('input[data-key]')) {
    input.addEventListener('input', () => {
      const key = input.dataset.key;
      const value = NUMBER_KEYS[key] === 'int' ? Number.parseInt(input.value, 10) : Number.parseFloat(input.value);
      const valid = Number.isFinite(value) && value >= Number(input.min || 0)
        && (!input.max || value <= Number(input.max));
      input.parentElement.classList.toggle('invalid', !valid);
      if (valid) setDraft(key, value);
    });
    input.addEventListener('blur', syncControls);
  }
  for (const el of document.querySelectorAll('select[data-key]')) {
    el.addEventListener('change', () => setDraft(el.dataset.key, el.value));
  }
  const level = async (delta) => {
    S.reader.level = Math.max(1, Math.min(14, S.reader.level + delta));
    await refreshMetrics();
    layout(S.pages > 1 ? S.page / (S.pages - 1) : 0);
  };
  $('level-down').addEventListener('click', () => level(-1));
  $('level-up').addEventListener('click', () => level(1));
  $('font').addEventListener('change', async () => {
    S.reader.font = $('font').value;
    await refreshMetrics();
    layout(S.pages > 1 ? S.page / (S.pages - 1) : 0);
  });
  $('device').addEventListener('change', async () => {
    S.device = S.devices.find((d) => d.id === $('device').value);
    drawDevice();
    await refreshMetrics();
    layout(S.pages > 1 ? S.page / (S.pages - 1) : 0);
  });
  $('chapter').addEventListener('change', () => {
    const [file, id] = $('chapter').value.split('#');
    const el = file === S.doc ? frame.contentDocument.getElementById(id) : null;
    if (el) show(pageOf(el));
    else if (S.spine.includes(file)) openDoc(file, { anchor: id });
  });
  $('apply').addEventListener('click', async () => {
    const values = {};
    for (const key of dirtyKeys()) values[key] = S.draft[key];
    $('apply').disabled = true;
    status('正在写回…');
    const r = await api('apply', { values });
    if (r.ok) {
      S.saved = { ...S.saved, ...values };
      status('已写回本书');
    } else {
      status(r.message || '写回失败', true);
    }
    syncControls();
  });
  $('revert').addEventListener('click', () => {
    S.draft = { ...S.saved };
    syncControls();
    scheduleRender();
  });
  $('prev').addEventListener('click', () => turn(false));
  $('next').addEventListener('click', () => turn(true));
  for (const [id, left] of [['tap-left', true], ['tap-right', false]]) {
    $(id).addEventListener('click', (event) => {
      const a = linkAt(event);
      if (a) followLink(a);
      else side(left);
    });
  }
  $('note-close').addEventListener('click', closeNote);
  $('note-body').addEventListener('click', (event) => {
    // 注释里的返回链接：关闭弹窗回到原位置，与 Kindle 一致。
    if (event.target.closest && event.target.closest('a')) {
      event.preventDefault();
      closeNote();
    }
  });
  document.addEventListener('keydown', keys);
  window.addEventListener('resize', drawDevice);
  // 回到窗口时：没有未写回的改动就同步排版页的最新值。
  window.addEventListener('focus', async () => {
    if (dirtyKeys().length) return;
    try {
      const state = await api('state');
      $('chapter-head').hidden = !state.chapter_head;
      showStyle(state);
      const values = pick(state.values);
      if (BOOK_KEYS.some((k) => String(values[k]) !== String(S.saved[k]))) {
        S.saved = values;
        S.draft = { ...values };
        syncControls();
        scheduleRender();
      }
    } catch (_) { /* 已提示 */ }
  });
}

function keys(event) {
  if (event.target && /^(INPUT|SELECT)$/.test(event.target.tagName)) return;
  if (event.key === 'Escape' && !$('note-pop').hidden) closeNote();
  else if (event.key === 'ArrowLeft') side(true);
  else if (event.key === 'ArrowRight') side(false);
  else if (event.key === 'PageDown' || event.key === ' ') turn(true);
  else if (event.key === 'PageUp') turn(false);
  else return;
  event.preventDefault();
}

async function start() {
  const state = await api('state');
  S.devices = state.devices;
  S.device = S.devices.find((d) => d.id === state.device) || S.devices[0];
  S.reader = { ...S.reader, ...state.reader };
  S.saved = pick(state.values);
  S.draft = { ...S.saved };
  S.title = state.title || '';
  document.title = '真机预览 · ' + S.title;
  $('book-title').textContent = '真机预览 · ' + S.title;
  $('font-unit').textContent = state.font_size_unit || '';
  // 章首图的范围与宽度只在本书设了章首图时显示（图片本身在排版页选择）。
  $('chapter-head').hidden = !state.chapter_head;
  showStyle(state);
  showSystem();
  const select = $('device');
  for (const d of S.devices) {
    const option = document.createElement('option');
    option.value = d.id;
    option.textContent = d.name;
    select.appendChild(option);
  }
  select.value = S.device.id;
  setupControls();
  syncControls();
  drawDevice();
  await refreshMetrics();
  await rerender(state.entry);
}

start().catch(() => { if ($('gone').hidden) status('预览没有打开，请回到排版页重试。', true); });
