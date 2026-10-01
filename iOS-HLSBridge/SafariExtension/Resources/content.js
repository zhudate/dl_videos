(() => {
  'use strict';
  if (window.top !== window) return;
  if (window.__HLSBRIDGE_EXTENSION_LOADED__) return;
  window.__HLSBRIDGE_EXTENSION_LOADED__ = true;

  const resources = new Map();
  let lastVideoMeta = null;
  let panelOpen = false;
  let root, button, panel, list;

  const isHLS = u => /\.m3u8(?:$|[?#])/i.test(String(u || ''));
  const isDirect = u => /\.(?:mp4|m4v|mov|webm)(?:$|[?#])/i.test(String(u || ''));
  const isSegment = u => /\.(?:m4s|cmfv|cmfa|ts|aac)(?:$|[?#])/i.test(String(u || ''));

  function abs(raw) {
    try { return new URL(String(raw || ''), location.href).href; } catch { return String(raw || ''); }
  }

  function base64url(obj) {
    const bytes = new TextEncoder().encode(JSON.stringify(obj));
    let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  }

  function pageMeta(video) {
    let poster = '';
    try { poster = video?.poster || document.querySelector('meta[property="og:image"]')?.content || ''; } catch (_) {}
    return {
      title: (document.querySelector('meta[property="og:title"]')?.content || document.title || '网页视频').trim(),
      poster: abs(poster),
      resolution: video?.videoWidth && video?.videoHeight ? `${video.videoWidth}×${video.videoHeight}` : '',
      duration: Number.isFinite(video?.duration) ? Number(video.duration) : 0
    };
  }

  function addResource(raw, meta = null) {
    const url = abs(raw);
    if (!url || /^blob:/i.test(url) || isSegment(url)) return;
    const type = isHLS(url) ? 'hls' : isDirect(url) ? 'direct' : null;
    if (!type) return;
    const old = resources.get(url) || { url, type, discoveredAt: Date.now() };
    old.type = type;
    const m = meta || lastVideoMeta || pageMeta(null);
    old.title = m.title || old.title || '网页视频';
    old.poster = m.poster || old.poster || '';
    old.resolution = m.resolution || old.resolution || '';
    old.duration = m.duration || old.duration || 0;
    resources.set(url, old);
    render();
  }

  function scanDOM() {
    document.querySelectorAll('video').forEach(v => {
      const meta = pageMeta(v);
      if (!lastVideoMeta && (v.currentSrc || v.src)) lastVideoMeta = meta;
      addResource(v.currentSrc || v.src, meta);
      v.querySelectorAll('source').forEach(s => addResource(s.src, meta));
      if (!v.__hlsBridgeBound) {
        v.__hlsBridgeBound = true;
        const update = () => { lastVideoMeta = pageMeta(v); addResource(v.currentSrc || v.src, lastVideoMeta); };
        v.addEventListener('play', update, true);
        v.addEventListener('loadedmetadata', update, true);
        v.addEventListener('durationchange', update, true);
      }
    });
    try {
      performance.getEntriesByType('resource').forEach(e => addResource(e.name));
    } catch (_) {}
  }

  try {
    new PerformanceObserver(list => {
      for (const e of list.getEntries()) addResource(e.name);
    }).observe({ type: 'resource', buffered: true });
  } catch (_) {}

  function collectCandidates(item) {
    const arr = [];
    const seen = new Set();
    const push = u => { u = abs(u); if (isHLS(u) && !seen.has(u)) { seen.add(u); arr.push(u); } };
    push(item.url);
    for (const r of resources.values()) if (r.type === 'hls') push(r.url);
    try { performance.getEntriesByType('resource').forEach(e => push(e.name)); } catch (_) {}
    let host = '';
    try { host = new URL(item.url).host; } catch (_) {}
    const same = arr.filter(u => { try { return !host || new URL(u).host === host; } catch { return false; } });
    return [...same, ...arr.filter(u => !same.includes(u))].slice(0, 20);
  }

  function sendToApp(item) {
    const payload = {
      version: 3,
      url: item.url,
      candidates: collectCandidates(item),
      title: item.title || document.title || '网页视频',
      poster: item.poster || '',
      pageUrl: location.href.split('#')[0],
      pageOrigin: location.origin || '',
      userAgent: navigator.userAgent || '',
      acceptLanguage: navigator.languages?.join(',') || navigator.language || '',
      visibleCookie: (() => { try { return document.cookie || ''; } catch { return ''; } })(),
      resolution: item.resolution || '',
      duration: Number(item.duration || 0)
    };
    location.href = `hlsbridge://add?p=${encodeURIComponent(base64url(payload))}`;
  }

  async function copyURL(url) {
    try { await navigator.clipboard.writeText(url); toast('已复制'); }
    catch (_) { window.prompt('长按复制视频地址', url); }
  }

  function fmtDuration(v) {
    if (!v || !Number.isFinite(v)) return '';
    const t = Math.round(v), h = Math.floor(t/3600), m = Math.floor(t%3600/60), s = t%60;
    return h ? `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}` : `${m}:${String(s).padStart(2,'0')}`;
  }

  function ensureUI() {
    if (root || !document.documentElement) return;
    root = document.createElement('div');
    root.id = 'hlsbridge-root';
    root.style.cssText = 'all:initial;position:fixed;right:16px;bottom:18px;z-index:2147483647;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;';
    const shadow = root.attachShadow({mode:'open'});
    shadow.innerHTML = `
      <style>
        *{box-sizing:border-box}button{font:inherit}#fab{width:50px;height:50px;border:0;border-radius:25px;background:#111;color:#fff;font-size:23px;box-shadow:0 4px 18px #0005;position:relative}#badge{position:absolute;right:-4px;top:-5px;min-width:20px;height:20px;padding:0 5px;border-radius:10px;background:#ff3b30;color:white;font:700 12px/20px -apple-system;text-align:center}.panel{display:none;position:absolute;right:0;bottom:60px;width:min(91vw,430px);max-height:70vh;overflow:auto;background:#f7f7f9;color:#111;border-radius:18px;box-shadow:0 12px 36px #0005;border:1px solid #ddd}.open{display:block}.head{position:sticky;top:0;background:#f7f7f9;padding:14px 14px 10px;border-bottom:1px solid #ddd;z-index:2}.title{font-size:20px;font-weight:800}.sub{font-size:12px;color:#666;margin-top:3px}.item{margin:10px;background:#fff;border:1px solid #ddd;border-radius:14px;padding:10px}.row{display:flex;gap:10px}.thumb{width:108px;height:76px;object-fit:cover;border-radius:10px;background:#eee}.info{min-width:0;flex:1}.kind{font-size:11px;font-weight:700;color:#9a5c00}.name{font-weight:750;font-size:15px;line-height:1.35;margin:3px 0}.meta,.url{font-size:11px;color:#777}.url{word-break:break-all;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}.actions{display:flex;gap:7px;margin-top:9px;flex-wrap:wrap}.actions button{border:0;border-radius:9px;padding:8px 11px;background:#ececf0;color:#111;font-weight:650}.actions .primary{background:#111;color:white}.empty{padding:24px;text-align:center;color:#777}
      </style>
      <button id="fab">🎬<span id="badge">0</span></button>
      <div id="panel" class="panel"><div class="head"><div class="title">页面视频</div><div class="sub">HLS 交给鼠标下载神器原生后台下载</div></div><div id="list"></div></div>`;
    button = shadow.getElementById('fab');
    panel = shadow.getElementById('panel');
    list = shadow.getElementById('list');
    button.onclick = () => { panelOpen = !panelOpen; panel.classList.toggle('open', panelOpen); if (panelOpen) scanDOM(); };
    document.documentElement.appendChild(root);
    render();
  }

  function render() {
    if (!root) return;
    const badge = root.shadowRoot.getElementById('badge');
    const items = [...resources.values()];
    badge.textContent = String(items.length);
    if (!list) return;
    if (!items.length) { list.innerHTML = '<div class="empty">播放一下视频后再点“重扫”</div>'; return; }
    list.innerHTML = '';
    items.forEach((it, idx) => {
      const el = document.createElement('div');
      el.className = 'item';
      const meta = [it.resolution, fmtDuration(it.duration)].filter(Boolean).join(' · ');
      el.innerHTML = `<div class="row"><div>${it.poster ? `<img class="thumb" src="${escapeHTML(it.poster)}">` : '<div class="thumb" style="display:grid;place-items:center;font-size:30px">🎬</div>'}</div><div class="info"><div class="kind">${it.type === 'hls' ? 'HLS / M3U8' : '直链视频'}</div><div class="name">#${idx+1} ${escapeHTML(it.title || '网页视频')}</div><div class="meta">${escapeHTML(meta)}</div><div class="url">${escapeHTML(it.url)}</div></div></div><div class="actions"></div>`;
      const actions = el.querySelector('.actions');
      const main = document.createElement('button');
      main.className = 'primary';
      main.textContent = it.type === 'hls' ? '下载到鼠标下载神器' : 'Safari 打开';
      main.onclick = () => it.type === 'hls' ? sendToApp(it) : window.open(it.url, '_blank');
      const copy = document.createElement('button'); copy.textContent = '复制'; copy.onclick = () => copyURL(it.url);
      const open = document.createElement('button'); open.textContent = '打开'; open.onclick = () => window.open(it.url, '_blank');
      actions.append(main, copy, open);
      list.appendChild(el);
    });
  }

  function escapeHTML(v) { return String(v || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  function toast(msg) {
    const n = document.createElement('div'); n.textContent = msg;
    n.style.cssText = 'position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:#111;color:#fff;padding:8px 14px;border-radius:10px;z-index:2147483647;font:14px -apple-system;';
    document.documentElement.appendChild(n); setTimeout(()=>n.remove(),1400);
  }

  const ready = () => { ensureUI(); scanDOM(); setInterval(scanDOM, 1500); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, {once:true}); else ready();
})();
