// 书源 JS 的运行环境（EasyPub 自写）：按阅读书源说明提供 java / source / book / chapter / cookie / cache。
// 所有本机能力经 __ep(操作, JSON 参数) 调用 Rust；字节数组用数字数组表示。
(function (g) {
  function call(op) {
    var args = Array.prototype.slice.call(arguments, 1);
    var out = __ep(op, JSON.stringify(args, function (k, v) { return v === undefined ? null : v; }));
    var r = JSON.parse(out);
    if (r && r.__error) throw new Error(r.__error);
    return r === null ? null : r.v;
  }
  g.__call = call;
  // 安装在 java 对象创建后；回存范围由 Rust 的本批 URL 集合校验。
  function str(x) { return x === undefined || x === null ? '' : String(x); }
  function bytes(x) {
    if (x === undefined || x === null) return null;
    if (typeof x === 'string') return { s: x };
    if (Array.isArray(x)) return { b: x };
    if (x.length !== undefined) return { b: Array.prototype.slice.call(x) };
    return { s: String(x) };
  }

  function response(r) {
    if (!r) return null;
    var res = {
      body: function () { return r.body; },
      code: function () { return r.code; },
      statusCode: function () { return r.code; },
      url: function () { return r.url; },
      header: function (name) { return r.headers[String(name).toLowerCase()] || null; },
      headers: function () { return r.headers; },
      message: function () { return ''; },
      raw: function () {
        return {
          request: function () { return { url: function () { return r.url; } }; },
          code: function () { return r.code; },
          headers: function () { return r.headers; },
          body: function () { return r.body; },
          header: function (name) { return r.headers[String(name).toLowerCase()] || null; },
        };
      },
      toString: function () { return r.body; },
    };
    return res;
  }

  var headerMap = {};
  Object.defineProperty(headerMap, 'put', { value: function (k, v) { this[k] = str(v); }, enumerable: false });
  Object.defineProperty(headerMap, 'get', { value: function (k) { return this[k]; }, enumerable: false });
  Object.defineProperty(headerMap, 'putAll', { value: function (m) { for (var k in m) this[k] = str(m[k]); }, enumerable: false });

  function crypto(transformation, key, iv) {
    var spec = { t: str(transformation), key: bytes(key), iv: bytes(iv) };
    function run(op, data, outEnc) { return call('crypto', spec, op, bytes(data), outEnc || null); }
    return {
      decrypt: function (d) { return run('decrypt', d, 'bytes'); },
      decryptStr: function (d) { return run('decrypt', d, 'utf8'); },
      encrypt: function (d) { return run('encrypt', d, 'bytes'); },
      encryptBase64: function (d) { return run('encrypt', d, 'base64'); },
      encryptHex: function (d) { return run('encrypt', d, 'hex'); },
      setIv: function (v) { spec.iv = bytes(v); return this; },
    };
  }

  var java = {
    headerMap: headerMap,
    url: '',
    // 变量与网络：java.get 一个参数取变量，两个参数为不跟随重定向的 GET。
    put: function (k, v) { call('varPut', str(k), str(v)); return v; },
    get: function (a, b) {
      if (arguments.length >= 2 && b !== null && typeof b === 'object') return response(call('http', 'GET', str(a), null, b, false));
      return call('varGet', str(a));
    },
    post: function (url, body, headers) { return response(call('http', 'POST', str(url), str(body), headers || {}, false)); },
    head: function (url, headers) { return response(call('http', 'HEAD', str(url), null, headers || {}, false)); },
    ajax: function (url) {
      var u = Array.isArray(url) ? url[0] : url;
      var r = call('ajax', str(u));
      return r === null ? null : r.body;
    },
    ajaxAll: function (urls) { return call('ajaxAll', urls.map(str)).map(response); },
    connect: function (url, header) { return response(call('ajax', str(url), header ? str(header) : null)); },
    // 规则
    getString: function (rule, content, isUrl) { return call('getString', str(rule), content === undefined ? null : str(content), !!isUrl); },
    getStringList: function (rule, content) { return call('getStringList', str(rule), content === undefined ? null : str(content)); },
    getElements: function (rule) {
      var r = call('getElements', str(rule));
      return r.length && r.every(function (x) { return typeof x === 'string'; }) ? jsoupElements(r, null, null) : r;
    },
    getElement: function (rule) { var e = java.getElements(rule); return e.length ? e[0] : null; },
    setContent: function (content, baseUrl) { call('setContent', str(content), baseUrl === undefined ? null : str(baseUrl)); },
    reGetBook: function () {}, refreshTocUrl: function () {},
    // 编码与哈希
    encodeURI: function (s, enc) { return call('encodeURI', str(s), enc ? str(enc) : null); },
    base64Encode: function (s, flags) { return call('base64Encode', bytes(s), flags || 2); },
    base64Decode: function (s, a, b) {
      var charset = typeof a === 'string' ? a : (typeof b === 'string' ? b : null);
      return call('base64Decode', str(s), charset);
    },
    base64DecodeToByteArray: function (s) { return call('base64DecodeBytes', str(s)); },
    hexDecodeToString: function (s) { return call('hexDecode', str(s), 'utf8'); },
    hexDecodeToByteArray: function (s) { return call('hexDecode', str(s), 'bytes'); },
    hexEncodeToString: function (s) { return call('hexEncode', bytes(s)); },
    strToBytes: function (s, charset) { return call('strToBytes', str(s), charset ? str(charset) : null); },
    bytesToStr: function (b, charset) { return call('bytesToStr', bytes(b), charset ? str(charset) : null); },
    md5Encode: function (s) { return call('digest', bytes(s), 'MD5', 32); },
    md5Encode16: function (s) { return call('digest', bytes(s), 'MD5', 16); },
    digestHex: function (s, algo) { return call('digest', bytes(s), str(algo), 0); },
    digestBase64Str: function (s, algo) { return call('digestBase64', bytes(s), str(algo)); },
    HMacHex: function (s, algo, key) { return call('hmac', bytes(s), str(algo), bytes(key), 'hex'); },
    HMacBase64: function (s, algo, key) { return call('hmac', bytes(s), str(algo), bytes(key), 'base64'); },
    createSymmetricCrypto: crypto,
    aesDecodeToString: function (d, key, t, iv) { return crypto(t, key, iv).decryptStr(d); },
    aesBase64DecodeToString: function (d, key, t, iv) { return crypto(t, key, iv).decryptStr(d); },
    aesEncodeToBase64String: function (d, key, t, iv) { return crypto(t, key, iv).encryptBase64(d); },
    aesEncodeToString: function (d, key, t, iv) { return crypto(t, key, iv).encryptBase64(d); },
    desDecodeToString: function (d, key, t, iv) { return crypto(t, key, iv).decryptStr(d); },
    desBase64DecodeToString: function (d, key, t, iv) { return crypto(t, key, iv).decryptStr(d); },
    desEncodeToBase64String: function (d, key, t, iv) { return crypto(t, key, iv).encryptBase64(d); },
    tripleDESDecodeStr: function (d, key, mode, padding, iv) { return crypto('DESede/' + mode + '/' + padding, key, iv).decryptStr(d); },
    tripleDESEncodeBase64Str: function (d, key, mode, padding, iv) { return crypto('DESede/' + mode + '/' + padding, key, iv).encryptBase64(d); },
    // 其他
    timeFormat: function (t) { return call('timeFormat', Number(t), 'yyyy/MM/dd HH:mm', 8); },
    timeFormatUTC: function (t, fmt, offset) { return call('timeFormat', Number(t), str(fmt), Number(offset || 0)); },
    t2s: function (s) { return call('t2s', str(s)); },
    s2t: function (s) { return call('s2t', str(s)); },
    toNumChapter: function (s) { return call('toNumChapter', str(s)); },
    htmlFormat: function (s) { return call('htmlFormat', str(s)); },
    randomUUID: function () { return call('uuid'); },
    androidId: function () { return 'easypub0000000000'; },
    getWebViewUA: function () { return call('userAgent'); },
    log: function (m) { call('log', str(m)); return m; },
    logType: function (m) { call('log', typeof m); },
    toast: function (m) { call('log', str(m)); },
    longToast: function (m) { call('log', str(m)); },
    getCookie: function (tag, key) { return key ? call('cookieKey', str(tag), str(key)) : call('cookieGet', str(tag)); },
    importScript: function (path) { var code = call('importScript', str(path)); return (0, eval)(code); },
    webView: function (html, url, js) { return call('webView', html === null || html === undefined ? null : str(html), url ? str(url) : null, js ? str(js) : null); },
    webViewGetSource: function (html, url, js, regex) { return call('webView', html === null || html === undefined ? null : str(html), url ? str(url) : null, js ? str(js) : null); },
    webViewGetOverrideUrl: function () { throw new Error('不支持 webViewGetOverrideUrl'); },
    startBrowser: function (url, title) { call('browser', str(url), title ? str(title) : null); },
    startBrowserAwait: function (url, title) { return response(call('browser', str(url), title ? str(title) : null)); },
    getVerificationCode: function (url) { return call('verificationCode', str(url)); },
    downloadFile: function () { throw new Error('不支持 downloadFile'); },
    readFile: function () { throw new Error('不支持读取本机文件'); },
    getBaseUrl: function () { return g.baseUrl; },
    initUrl: function () {},
  };
  // Rhino 写法 java.lang.String(…)、java.net.URLEncoder 等的常用替代。
  java.lang = {
    String: function (x, charset) { return Array.isArray(x) ? call('bytesToStr', bytes(x), charset ? str(charset) : null) : str(x); },
    Integer: { parseInt: function (s, r) { return parseInt(s, r || 10); }, valueOf: function (s) { return parseInt(s, 10); } },
    Long: { parseLong: function (s) { return parseInt(s, 10); }, valueOf: function (s) { return parseInt(s, 10); } },
    Math: Math,
    System: { currentTimeMillis: function () { return Date.now(); } },
  };
  java.net = {
    URLEncoder: { encode: function (s, enc) { return call('encodeURI', str(s), enc ? str(enc) : null); } },
    URLDecoder: { decode: function (s, enc) { return call('decodeURI', str(s), enc ? str(enc) : null); } },
  };
  java.util = { UUID: { randomUUID: function () { return call('uuid'); } } };
  // org.jsoup 的常用部分：parse → select → text / attr / html / remove，元素以外层 HTML 表示。
  function jsoupElements(list, doc, css) {
    var els = list.map(function (h) { return jsoupElement(h); });
    function def(o, k, v) { Object.defineProperty(o, k, { value: v, enumerable: false, writable: true }); }
    def(els, 'size', function () { return els.length; });
    def(els, 'isEmpty', function () { return els.length === 0; });
    def(els, 'get', function (i) { return els[i]; });
    def(els, 'first', function () { return els.length ? els[0] : null; });
    def(els, 'last', function () { return els.length ? els[els.length - 1] : null; });
    def(els, 'eq', function (i) { return jsoupElements(els[i] ? [els[i].__html] : [], doc, null); });
    def(els, 'text', function () { return els.map(function (e) { return e.text(); }).filter(function (t) { return t; }).join(' '); });
    def(els, 'eachText', function () { return els.map(function (e) { return e.text(); }); });
    def(els, 'html', function () { return els.map(function (e) { return e.html(); }).join('\n'); });
    def(els, 'outerHtml', function () { return els.map(function (e) { return e.__html; }).join('\n'); });
    def(els, 'attr', function (a) { for (var i = 0; i < els.length; i++) { var v = els[i].attr(a); if (v) return v; } return ''; });
    def(els, 'eachAttr', function (a) { return els.map(function (e) { return e.attr(a); }); });
    def(els, 'hasAttr', function (a) { return els.some(function (e) { return e.hasAttr(a); }); });
    def(els, 'select', function (c) { var out = []; els.forEach(function (e) { out = out.concat(call('jsoupSelect', e.__html, str(c))); }); return jsoupElements(out, doc, null); });
    def(els, 'remove', function () { if (doc && css) doc.__html = call('jsoupRemove', doc.__html, css); return els; });
    def(els, 'toArray', function () { return els.slice(); });
    def(els, 'toString', els.outerHtml);
    return els;
  }
  function jsoupElement(html) {
    var e = { __html: html };
    e.text = function () { return call('jsoupValue', e.__html, 'text'); };
    e.ownText = function () { return call('jsoupValue', e.__html, 'ownText'); };
    e.html = function () { return call('jsoupValue', e.__html, 'inner'); };
    e.outerHtml = function () { return e.__html; };
    e.attr = function (a) {
      a = str(a);
      if (a.indexOf('abs:') === 0) return call('absolute', call('jsoupValue', e.__html, 'attr:' + a.slice(4)));
      return call('jsoupValue', e.__html, 'attr:' + a);
    };
    e.absUrl = function (a) { return call('absolute', call('jsoupValue', e.__html, 'attr:' + str(a))); };
    e.hasAttr = function (a) { return call('jsoupValue', e.__html, 'has:' + str(a)) === 'true'; };
    e.tagName = function () { return call('jsoupValue', e.__html, 'tag'); };
    e.className = function () { return e.attr('class'); };
    e.hasClass = function (c) { return (' ' + e.attr('class') + ' ').indexOf(' ' + c + ' ') >= 0; };
    e.id = function () { return e.attr('id'); };
    e.select = function (c) { return jsoupElements(call('jsoupSelect', e.__html, str(c)), e, str(c)); };
    e.selectFirst = function (c) { var r = e.select(c); return r.length ? r[0] : null; };
    e.children = function () { return jsoupElements(call('jsoupSelect', e.__html, ':scope > *'), e, null); };
    e.child = function (i) { return e.children()[i] || null; };
    e.getElementsByTag = function (t) { return e.select(t); };
    e.getElementsByClass = function (c) { return e.select('.' + c); };
    e.getElementById = function (i) { return e.selectFirst('#' + i); };
    e.body = function () { return e.selectFirst('body') || e; };
    e.head = function () { return e.selectFirst('head') || e; };
    e.title = function () { var t = e.selectFirst('title'); return t ? t.text() : ''; };
    e.toString = function () { return e.__html; };
    e.toJSON = function () { return e.__html; };
    // 当字符串用的常见写法。
    e.match = function (r) { return e.__html.match(r); };
    e.replace = function (a, b) { return e.__html.replace(a, b); };
    e.indexOf = function (x) { return e.__html.indexOf(x); };
    e.includes = function (x) { return e.__html.indexOf(x) >= 0; };
    return e;
  }
  g.__make_element = jsoupElement;
  g.__make_elements = function (list) { return jsoupElements(list, null, null); };
  var Jsoup = {
    parse: function (html) { return jsoupElement(str(html)); },
    parseBodyFragment: function (html) { return jsoupElement(str(html)); },
    clean: function (html) { return call('htmlFormat', str(html)); },
  };
  g.org = { jsoup: { Jsoup: Jsoup, nodes: { Document: {}, Element: {} } } };

  g.java = java;
  g.Packages = { java: java, org: g.org };
  g.JavaImporter = function () { return {}; };
  g.importPackage = function () {};
  g.importClass = function () {};

  g.cookie = {
    getCookie: function (url) { return call('cookieGet', str(url)); },
    getKey: function (url, key) { return call('cookieKey', str(url), str(key)); },
    setCookie: function (url, c) { call('cookieSet', str(url), str(c)); },
    replaceCookie: function (url, c) { call('cookieSet', str(url), str(c)); },
    removeCookie: function (url) { call('cookieRemove', str(url)); },
  };
  g.cache = {
    get: function (k) { return call('cacheGet', str(k)); },
    put: function (k, v) { call('cachePut', str(k), str(v)); },
    delete: function (k) { call('cachePut', str(k), null); },
    getFromMemory: function (k) { return call('cacheGet', str(k)); },
    putMemory: function (k, v) { call('cachePut', str(k), str(v)); },
    deleteMemory: function (k) { call('cachePut', str(k), null); },
    getFile: function (k) { return call('cacheGet', str(k)); },
    putFile: function (k, v) { call('cachePut', str(k), str(v)); },
  };

  // source / book / chapter 在每次执行前由 Rust 设置数据（__source_data 等），方法在这里补上。
  function withVariables(o, kind) {
    o.getVariable = function (k) { return call('objVarGet', kind, k === undefined ? null : str(k)); };
    o.putVariable = function (k, v) { call('objVarPut', kind, str(k), str(v)); };
    o.setVariable = function (v) { call('objVarPut', kind, null, str(v)); };
    return o;
  }
  g.__make_source = function (data) {
    var s = withVariables(data, 'source');
    s.getKey = function () { return data.bookSourceUrl; };
    s.key = data.bookSourceUrl;
    s.put = function (k, v) { call('sourcePut', str(k), str(v)); return v; };
    s.get = function (k) { return call('sourceGet', str(k)); };
    s.getLoginInfo = function () { return call('loginInfo'); };
    s.getLoginInfoMap = function () { var i = call('loginInfo'); try { return i ? JSON.parse(i) : {}; } catch (e) { return {}; } };
    s.getLoginHeader = function () { return null; };
    s.getLoginHeaderMap = function () { return {}; };
    s.putLoginHeader = function () {}; s.removeLoginHeader = function () {};
    s.getHeaderMap = function () { return call('sourceHeaders'); };
    s.getTag = function () { return data.bookSourceName; };
    s.login = function () {};
    return s;
  };
  g.__make_book = function (data) { return withVariables(data, 'book'); };
  g.__make_chapter = function (data) { return withVariables(data, 'chapter'); };

  // 每段脚本在函数里直接 eval：顶层 let 只在本段有效，返回最后一个表达式的值。
  g.java.cacheContent = function (chapter, content) { return call('cacheContent', chapter, str(content)); };
  g.__run = function (__code) { return eval(__code); };
})(globalThis);
