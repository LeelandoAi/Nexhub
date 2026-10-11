/*
 * NexHub sniffer hook (clean-room reimplementation, no third-party code).
 *
 * Methodology (inspired by generic "network interception + DOM detection +
 * API hooking" sniffers): hook the browser's network / media APIs at
 * document-start, capture the real stream URLs that players wrap, and report
 * them back to Dart via window.flutter_inappwebview.callHandler('sniffer', ...).
 *
 * No site-specific logic lives here. The Dart side filters noise by rules.
 *
 * Because callHandler is only available after the `flutterInAppWebViewPlatformReady`
 * event, captured URLs are buffered and flushed once the platform is ready.
 */
(function () {
  'use strict';

  // ---- report buffer (handles the gap before the platform is ready) ----
  var queue = [];
  var ready = false;

  // ---- capture log (lets Dart query the best play target without polling callHandler) ----
  var log = [];
  var logSeen = {};

  function record(u, k, r) {
    if (!u || logSeen[u]) return;
    logSeen[u] = true;
    log.push({ u: u, k: k || '', r: r || '' });
  }

  function flush() {
    ready = true;
    var q = queue;
    queue = [];
    for (var i = 0; i < q.length; i++) {
      try {
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('sniffer', q[i].u, q[i].k, q[i].r, q[i].m);
        }
      } catch (e) {
        /* best-effort */
      }
    }
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', flush);

  // mime 可选：响应阶段拿到 Content-Type 后二次上报，Dart 侧凭 MIME“翻案”
  // 识别无扩展名串流（猫爪 onResponseStarted 以响应 MIME 定性的等价机制）。
  function report(url, kind, ref, mime) {
    if (!url || typeof url !== 'string') return;
    record(url, kind, ref);
    if (ready && window.flutter_inappwebview) {
      try {
        window.flutter_inappwebview.callHandler('sniffer', url, kind || '', ref || '', mime || '');
      } catch (e) {
        /* ignore */
      }
    } else {
      queue.push({ u: url, k: kind || '', r: ref || '', m: mime || '' });
    }
  }

  function safeLower(s) {
    return (typeof s === 'string') ? s.toLowerCase() : '';
  }

  // ---- fetch ----
  if (typeof window.fetch === 'function') {
    var origFetch = window.fetch;
    window.fetch = function (input, init) {
      try {
        var u = (typeof input === 'string')
          ? input
          : (input && input.url) ? input.url : null;
        var ref = '';
        if (init && init.headers) {
          var h = init.headers;
          if (h instanceof Headers) {
            ref = h.get('referer') || h.get('Referrer') || '';
          } else if (typeof h === 'object') {
            ref = h['referer'] || h['Referrer'] || h['Referer'] || '';
          }
        }
        if (u) report(u, 'fetch', ref);
      } catch (e) {
        /* ignore */
      }
      var p = origFetch.apply(this, arguments);
      // 响应阶段：读取 Content-Type 二次上报（凭 MIME 识别无扩展名串流）。
      try {
        var u2 = (typeof input === 'string')
          ? input
          : (input && input.url) ? input.url : null;
        if (u2 && p && typeof p.then === 'function') {
          p.then(function (resp) {
            try {
              var ct = resp && resp.headers ? resp.headers.get('content-type') : '';
              if (ct) report(u2, 'fetch', '', ct);
            } catch (e) { /* ignore */ }
          }, function () { /* ignore */ });
        }
      } catch (e) { /* ignore */ }
      return p;
    };
  }

  // ---- XMLHttpRequest (capture Referer via setRequestHeader) ----
  if (typeof window.XMLHttpRequest === 'function' &&
      window.XMLHttpRequest.prototype && window.XMLHttpRequest.prototype.open) {
    var origOpen = window.XMLHttpRequest.prototype.open;
    var origSetHeader = window.XMLHttpRequest.prototype.setRequestHeader;
    var origSend = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.open = function (method, url) {
      // 每次请求重置该实例记录的 Referer，并记录 URL 供 send 时携带。
      this.__sniffRef = '';
      this.__sniffUrl = (typeof url === 'string') ? url : '';
      try {
        if (typeof url === 'string') report(url, 'xhr', '');
      } catch (e) {
        /* ignore */
      }
      return origOpen.apply(this, arguments);
    };
    if (typeof origSetHeader === 'function') {
      window.XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try {
          if (name && typeof name === 'string' &&
              (safeLower(name) === 'referer' || safeLower(name) === 'referrer')) {
            this.__sniffRef = (typeof value === 'string') ? value : '';
          }
        } catch (e) { /* ignore */ }
        return origSetHeader.apply(this, arguments);
      };
    }
    if (typeof origSend === 'function') {
      window.XMLHttpRequest.prototype.send = function () {
        try {
          if (this.__sniffRef) report(this.__sniffUrl || '', 'xhr', this.__sniffRef);
        } catch (e) { /* ignore */ }
        // 响应阶段：读取 Content-Type 二次上报（凭 MIME 识别无扩展名串流）。
        try {
          var xhr = this;
          xhr.addEventListener('readystatechange', function () {
            try {
              if (xhr.readyState >= 2 && !xhr.__sniffMimeSent && xhr.__sniffUrl) {
                var ct = xhr.getResponseHeader('content-type');
                if (ct) {
                  xhr.__sniffMimeSent = true;
                  report(xhr.__sniffUrl, 'xhr', xhr.__sniffRef || '', ct);
                }
              }
            } catch (e) { /* ignore */ }
          });
        } catch (e) { /* ignore */ }
        return origSend.apply(this, arguments);
      };
    }
  }

  // ---- HTMLMediaElement.src setter (blob:/mediasource:/http) ----
  try {
    if (window.HTMLMediaElement && HTMLMediaElement.prototype) {
      var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (srcDesc && srcDesc.set) {
        var origSetSrc = srcDesc.set;
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          enumerable: srcDesc.enumerable,
          get: srcDesc.get,
          set: function (v) {
            try {
              if (typeof v === 'string' && v.length) report(v, 'media', '');
            } catch (e) { /* ignore */ }
            return origSetSrc.call(this, v);
          }
        });
      }
    }
  } catch (e) { /* ignore */ }

  // ---- Element.setAttribute hook (media/src attributes) ----
  // 不少播放器用 setAttribute('src', url) 或 data-* 惰性属性挂直链，不走 src
  // 属性 setter——这是常见嗅探器（猫抓等）的标准覆盖面之一。
  // 上报门槛：媒体/源元素上的 src 类属性，或属性值本身是媒体直链；其余忽略防噪。
  try {
    if (window.Element && Element.prototype && Element.prototype.setAttribute) {
      var origSetAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        try {
          if (typeof name === 'string' && typeof value === 'string' && value.length > 10) {
            var n = name.toLowerCase();
            if (n === 'src' || n === 'data-src' || n === 'data-url' ||
                n === 'data-video' || n === 'data-original' || n === 'data-mp4') {
              var tag = (this && this.tagName) ? String(this.tagName).toUpperCase() : '';
              var isMediaEl = tag === 'VIDEO' || tag === 'SOURCE' ||
                  tag === 'AUDIO' || tag === 'EMBED';
              if (isMediaEl || looksLikeMediaUrl(value)) report(value, 'media', '');
            }
          }
        } catch (e) { /* ignore */ }
        return origSetAttr.call(this, name, value);
      };
    }
  } catch (e) { /* ignore */ }

  // ---- URL.createObjectURL (captures blob:/mediasource: handles) ----
  try {
    if (window.URL && typeof URL.createObjectURL === 'function') {
      var origCreate = URL.createObjectURL;
      URL.createObjectURL = function (obj) {
        var r = origCreate.apply(this, arguments);
        try {
          if (typeof r === 'string') report(r, 'blob', '');
        } catch (e) { /* ignore */ }
        return r;
      };
    }
  } catch (e) { /* ignore */ }

  // ---- MediaSource.addSourceBuffer (hint that MSE streaming is in use) ----
  try {
    if (window.MediaSource && MediaSource.prototype && MediaSource.prototype.addSourceBuffer) {
      var origAdd = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) {
        try {
          if (typeof mime === 'string' && mime.length) {
            report('mediasource:' + mime, 'mse', '');
          }
        } catch (e) { /* ignore */ }
        return origAdd.apply(this, arguments);
      };
    }
  } catch (e) { /* ignore */ }

  // ---- deep DOM scan (invoked from Dart after load, for static <video>/<source>) ----
  // 递归扫描同域 iframe（跨域会抛异常，忽略）——这是猫爪覆盖 iframe 播放器的关键。
  function __scanDoc(doc) {
    if (!doc) return;
    try {
      var els = doc.querySelectorAll('video, video > source, source');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var s = el.getAttribute('src');
        if (s) report(s, 'media', '');
        // currentSrc 兜底：src 由 JS 换源后 attribute 可能缺失，currentSrc 始终
        // 指向实际加载的资源（含 blob:，Dart 侧引擎去重）。
        if (el.tagName === 'VIDEO' && el.currentSrc) report(el.currentSrc, 'media', '');
      }
      // 惰性属性：data-src / data-original / data-url / data-video（懒加载播放器常用），
      // 仅当值本身是媒体直链时上报，避免把图片懒加载属性当视频。
      var lazy = doc.querySelectorAll('[data-src],[data-original],[data-url],[data-video],[data-mp4]');
      for (var d = 0; d < lazy.length; d++) {
        var le = lazy[d];
        var attrs = ['data-src', 'data-original', 'data-url', 'data-video', 'data-mp4'];
        for (var a = 0; a < attrs.length; a++) {
          var lv = le.getAttribute(attrs[a]);
          if (lv && looksLikeMediaUrl(lv)) { report(lv, 'media', ''); break; }
        }
      }
      // MacCMS 标准播放配置（player_aaaa / player_data，大量影视站通用约定）：
      // encrypt=1 → unescape（%XX 还原），encrypt=2 → unescape(base64decode)。
      // 解码结果是媒体直链才上报，加密令牌/广告占位不收。
      var win = doc.defaultView || window;
      var cfgs = [win.player_aaaa, win.player_data];
      for (var c = 0; c < cfgs.length; c++) {
        var cfg = cfgs[c];
        if (!cfg || typeof cfg !== 'object' || !cfg.url) continue;
        var cu = String(cfg.url);
        try {
          if (String(cfg.encrypt) === '2') cu = unescape(__b64decode(cu));
          else if (String(cfg.encrypt) === '1') cu = unescape(cu);
        } catch (e) { /* 解码失败按原样判断 */ }
        if (looksLikeMediaUrl(cu)) report(cu, 'media', '');
      }
      if (doc === document && window.player_ && typeof window.player_ === 'object') {
        var p = window.player_;
        if (p && p.url) report(String(p.url), 'media', '');
      }
      var frames = doc.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        try {
          var idoc = frames[f].contentDocument;
          if (idoc) __scanDoc(idoc);
        } catch (err) {
          /* cross-origin: ignore */
        }
      }
    } catch (e) {
      /* ignore */
    }
  }

  window.__sniffDeepScan = function () {
    __scanDoc(document);
  };

  // ---- best play target (used by Dart for blob/mediasource in-page fallback) ----
  function isMediaHttp(u) {
    if (u.indexOf('http://') !== 0 && u.indexOf('https://') !== 0) return false;
    var lower = safeLower(u);
    var q = lower.indexOf('?');
    if (q >= 0) lower = lower.substring(0, q);
    return /\.(m3u8|m3u|mpd|mp4|ts|m4s|mov|webm|flv|mkv|avi|3gp|mp3|aac|wav|ogg|m4a|oga)(\?|$)/.test(lower) ||
           lower.indexOf('manifest') >= 0;
  }

  // 比 isMediaHttp 宽：扩展名允许出现在查询串中（player.php?url=xxx.m3u8），
  // 用于 setAttribute / data-* / MacCMS 配置值的上报门槛。
  function looksLikeMediaUrl(u) {
    if (typeof u !== 'string') return false;
    if (u.indexOf('http://') !== 0 && u.indexOf('https://') !== 0) return false;
    if (isMediaHttp(u)) return true;
    return /\.(m3u8|m3u|mpd|mp4|ts|m4s|mov|webm|flv|mkv|avi|3gp|mp3|aac|wav|ogg|m4a|oga)(?=$|[?#&/])/.test(safeLower(u));
  }

  // 标准 base64 解码（atob 不可用时兜底，处理 URL-safe 变体）。
  function __b64decode(s) {
    var t = String(s).replace(/-/g, '+').replace(/_/g, '/');
    while (t.length % 4 !== 0) t += '=';
    if (typeof atob === 'function') return atob(t);
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var out = '', bits = 0, acc = 0;
    for (var i = 0; i < t.length; i++) {
      var c = chars.indexOf(t.charAt(i));
      if (c < 0 || t.charAt(i) === '=') continue;
      acc = (acc << 6) | c;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((acc >> bits) & 0xff);
      }
    }
    return out;
  }

  // 返回最佳可播放目标：{mode:'http'|'webview', url, ref}；无则 null。
  // - 'http'：真实直链，可在 WebView 外播放；
  // - 'webview'：仅 blob:/mediasource:/mse，只能在当前页面内播放（location.href）。
  window.__sniffBestPlay = function () {
    try {
      for (var i = 0; i < log.length; i++) {
        var e = log[i];
        if (isMediaHttp(e.u)) {
          return { mode: 'http', url: e.u, ref: e.r || '' };
        }
      }
      for (var j = 0; j < log.length; j++) {
        var b = log[j];
        if (b.u.indexOf('blob:') === 0 || b.u.indexOf('mediasource:') === 0 ||
            b.k === 'mse') {
          return { mode: 'webview', url: location.href, ref: b.r || '' };
        }
      }
    } catch (err) {
      /* ignore */
    }
    return null;
  };
})();
