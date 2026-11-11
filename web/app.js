'use strict';

/*
 * 후면캠 웹앱
 *
 * 고장 난 광각(1×) 카메라를 피해서 초광각(0.5×) 카메라만 연다.
 * - 후면 기본 카메라(facingMode: 'environment')는 고장 난 광각이나 듀얼 카메라로 열릴 수 있으므로 쓰지 않는다.
 *   대신 카메라 목록에서 "초광각 / Ultra Wide" 카메라를 찾아 deviceId 로 직접 연다.
 * - 사진은 영상 스트림의 프레임을 캔버스로 떠서 JPEG 로 만든다. (사진 처리 파이프라인을 거치지 않음)
 * - 1×, 2× 는 카메라가 zoom 을 지원하면 하드웨어 줌, 아니면 화면 확대 + 가운데 잘라내기로 만든다.
 * - 찍은 결과는 IndexedDB 에 임시 보관하고, 공유 시트(“이미지 저장”/“비디오 저장”)로 사진 앱에 넣는다.
 */

const $ = (sel) => document.querySelector(sel);

const els = {
  app: $('#app'),
  topbar: $('#topbar'),
  bottombar: $('#bottombar'),
  btnAspect: $('#btn-aspect'),
  video: $('#video'),
  stage: $('#stage'),
  viewport: $('#viewport'),
  grid: $('#grid'),
  flash: $('#flash'),
  message: $('#message'),
  messageText: $('#message-text'),
  btnStart: $('#btn-start'),
  zoombar: $('#zoombar'),
  modes: $('#modes'),
  recTime: $('#rec-time'),
  formatInfo: $('#format-info'),
  btnSettings: $('#btn-settings'),
  btnGallery: $('#btn-gallery'),
  thumbImg: $('#thumb-img'),
  badge: $('#badge'),
  btnShutter: $('#btn-shutter'),
  btnFlip: $('#btn-flip'),
  toast: $('#toast'),
  toastText: $('#toast-text'),
  toastSave: $('#toast-save'),
  gallery: $('#gallery'),
  galleryGrid: $('#gallery-grid'),
  galleryEmpty: $('#gallery-empty'),
  btnSaveAll: $('#btn-save-all'),
  btnClear: $('#btn-clear'),
  viewer: $('#viewer'),
  viewerTitle: $('#viewer-title'),
  viewerBody: $('#viewer-body'),
  viewerSave: $('#viewer-save'),
  viewerDelete: $('#viewer-delete'),
  settings: $('#settings'),
  setCamera: $('#set-camera'),
  setPhotoRes: $('#set-photo-res'),
  setVideoRes: $('#set-video-res'),
  setGrid: $('#set-grid'),
  setSound: $('#set-sound'),
  setAutoSave: $('#set-autosave'),
  setSharpen: $('#set-sharpen'),
  diag: $('#diag'),
  btnCopyDiag: $('#btn-copy-diag'),
  btnRescan: $('#btn-rescan'),
  canvas: $('#capture-canvas'),
  tip: $('#tip'),
  tipClose: $('#tip-close'),
};

// ---------------------------------------------------------------- 설정

const SETTINGS_KEY = 'rearcam.settings.v1';

function loadSettings() {
  try {
    return JSON.parse(localStorage.getItem(SETTINGS_KEY)) || {};
  } catch (_) {
    return {};
  }
}

const SETTINGS_VERSION = 3;

const settings = Object.assign(
  { backDeviceId: null, backLabel: null, photoRes: 'max', videoRes: '4k', grid: false, sound: true, autoSave: true, sharpen: true, aspect: '4:3' },
  loadSettings()
);
if (!settings.version || settings.version < 2) {
  // v1 은 한국어 카메라 이름("울트라 와이드")을 못 알아봐서 수동 선택이 저장됐을 수 있다 → 자동 감지로 초기화
  settings.backDeviceId = null;
  settings.backLabel = null;
}
if (!settings.version || settings.version < 3) {
  // 1× 는 화면을 잘라서 만드므로 1080p 원본으로는 960×540 밖에 안 남는다 → 4K 를 기본으로
  if (settings.videoRes === '1080') settings.videoRes = '4k';
}
settings.version = SETTINGS_VERSION;

function saveSettings() {
  settings.version = SETTINGS_VERSION;
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch (_) { /* 비공개 브라우징 등 */ }
}

const RES = {
  photo: { max: [4032, 3024], mid: [1920, 1440] },
  video: { '4k': [3840, 2160], '1080': [1920, 1080], '720': [1280, 720] },
};
const BITRATE = { '4k': 30e6, '1080': 12e6, '720': 6e6 };
const SW_MAX_FACTOR = 6; // 소프트웨어 줌 최대 배율 (초광각 기준 3×)

// iOS Safari 카메라 이름 예: "Back Ultra Wide Camera", "후면 울트라 와이드 카메라"
const UW_RE = /ultra\s*-?\s*wide|울트라\s*-?\s*와이드|초광각/i;
const MULTI_RE = /dual|triple|듀얼|트리플/i;
const FRONT_RE = /front|전면|facetime/i;

// ---------------------------------------------------------------- 상태

const state = {
  mode: 'photo',
  facing: 'back',
  cameras: [],
  device: null,
  stream: null,
  track: null,
  videoConstraints: null,
  multiplier: 0.5,
  zoom: 1,
  desired: { back: 1, front: 1 },
  hwZoom: null,
  swFactor: 1,
  zoomLocked: false,
  recorder: null,
  recChunks: [],
  recStart: 0,
  recTimer: null,
  recLoop: null,
  recCanvasStream: null,
  starting: false,
  restartQueued: false,
  items: [],
  dbOk: true,
  audioCtx: null,
  toastTimer: null,
  toastItem: null,
  viewerItem: null,
  viewerUrl: null,
};

class AppError extends Error {}

// ---------------------------------------------------------------- 저장소 (IndexedDB)

const db = (() => {
  let opening = null;

  function open() {
    if (opening) return opening;
    opening = new Promise((resolve, reject) => {
      const req = indexedDB.open('rearcam', 1);
      req.onupgradeneeded = () => req.result.createObjectStore('items', { keyPath: 'id' });
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    return opening;
  }

  async function run(mode, fn) {
    const database = await open();
    return new Promise((resolve, reject) => {
      const tx = database.transaction('items', mode);
      const request = fn(tx.objectStore('items'));
      tx.oncomplete = () => resolve(request ? request.result : undefined);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  }

  return {
    all: () => run('readonly', (s) => s.getAll()),
    put: (item) => run('readwrite', (s) => s.put(item)),
    del: (id) => run('readwrite', (s) => s.delete(id)),
    clear: () => run('readwrite', (s) => s.clear()),
  };
})();

async function loadItems() {
  try {
    const items = await db.all();
    state.items = (items || []).sort((a, b) => a.created - b.created);
  } catch (e) {
    state.dbOk = false;
    state.items = [];
  }
  updateThumb();
}

function addItem(type, blob, ext, thumb) {
  const item = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    type,
    ext,
    blob,
    thumb,
    created: Date.now(),
    saved: false,
  };
  state.items.push(item);
  if (state.dbOk) {
    db.put(item).catch(() => {
      state.dbOk = false;
    });
  }
  updateThumb();
  return item;
}

function canShareFiles() {
  try {
    return !!(navigator.canShare && navigator.canShare({ files: [new File([''], 'a.jpg', { type: 'image/jpeg' })] }));
  } catch (_) {
    return false;
  }
}

/** 촬영 직후 공유 시트를 띄운다. 실패(탭 이벤트 만료 등)하거나 취소하면 저장 버튼 토스트로 대체. */
function autoSaveItem(item, label) {
  if (settings.autoSave && canShareFiles()) {
    shareItems([item], { quiet: true }).then((ok) => {
      if (!ok) showToast(label, item);
    });
  } else {
    showToast(label, item);
  }
}

function dataUrlToBlob(url) {
  const comma = url.indexOf(',');
  const mime = (url.slice(0, comma).match(/:(.*?);/) || [])[1] || 'image/jpeg';
  const binary = atob(url.slice(comma + 1));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new Blob([bytes], { type: mime });
}

async function removeItem(item) {
  state.items = state.items.filter((it) => it.id !== item.id);
  if (state.dbOk) {
    try { await db.del(item.id); } catch (_) { /* 무시 */ }
  }
  updateThumb();
}

function fileName(item) {
  const d = new Date(item.created);
  const p = (n) => String(n).padStart(2, '0');
  return `RearCam_${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.${item.ext}`;
}

function mimeOf(item) {
  if (item.blob && item.blob.type) return item.blob.type.split(';')[0];
  return item.type === 'photo' ? 'image/jpeg' : 'video/mp4';
}

/** 공유 시트를 연다. 반드시 사용자 탭 이벤트 안에서 호출해야 한다. */
async function shareItems(items, { quiet = false } = {}) {
  if (!items.length) return false;
  const files = items.map((it) => new File([it.blob], fileName(it), { type: mimeOf(it) }));

  if (navigator.canShare && navigator.canShare({ files })) {
    try {
      await navigator.share({ files });
    } catch (e) {
      if (e && e.name === 'AbortError') return false;
      if (!quiet) alert('공유 창을 열지 못했습니다: ' + (e && e.message ? e.message : e));
      return false;
    }
  } else {
    // 공유를 지원하지 않는 브라우저: 파일 다운로드로 대체
    for (const it of items) {
      const url = URL.createObjectURL(it.blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = fileName(it);
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
    }
  }

  for (const it of items) {
    it.saved = true;
    if (state.dbOk) db.put(it).catch(() => {});
  }
  updateThumb();
  if (!els.gallery.hidden) renderGallery();
  return true;
}

// ---------------------------------------------------------------- 카메라

async function getCameras() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  return devices.filter((d) => d.kind === 'videoinput');
}

async function ensureCameraLabels() {
  const cams = await getCameras();
  if (cams.length && cams.every((c) => c.label)) return cams;
  // 카메라 이름을 보려면 권한이 필요하다.
  // 후면 기본 카메라는 고장 난 광각일 수 있으므로, 권한은 전면 카메라로 잠깐 열어서 받는다.
  const probe = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user' }, audio: false });
  probe.getTracks().forEach((t) => t.stop());
  return getCameras();
}

function findBackCamera(cams) {
  if (settings.backDeviceId) {
    const byId = cams.find((c) => c.deviceId === settings.backDeviceId);
    if (byId) return byId;
    if (settings.backLabel) {
      const byLabel = cams.find((c) => c.label === settings.backLabel);
      if (byLabel) return byLabel;
    }
  }
  return cams.find((c) => UW_RE.test(c.label) && !MULTI_RE.test(c.label)) || null;
}

function findFrontCamera(cams) {
  return cams.find((c) => FRONT_RE.test(c.label)) || null;
}

function stopStream() {
  if (state.stream) {
    state.stream.getTracks().forEach((t) => t.stop());
  }
  state.stream = null;
  state.track = null;
  els.video.srcObject = null;
}

function waitForVideoSize(timeout = 3000) {
  const v = els.video;
  if (v.videoWidth && v.videoHeight) return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => {
      v.removeEventListener('loadedmetadata', check);
      v.removeEventListener('resize', check);
      resolve();
    };
    const check = () => { if (v.videoWidth && v.videoHeight) done(); };
    v.addEventListener('loadedmetadata', check);
    v.addEventListener('resize', check);
    setTimeout(done, timeout);
  });
}

async function startCamera() {
  if (state.starting) {
    state.restartQueued = true;
    return;
  }
  state.starting = true;
  hideMessage();

  try {
    if (!window.isSecureContext) {
      throw new AppError('카메라는 https 주소에서만 쓸 수 있습니다.');
    }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      throw new AppError('이 브라우저는 카메라를 지원하지 않습니다.\niPhone의 Safari로 열어 주세요.');
    }

    stopStream();
    state.cameras = await ensureCameraLabels();
    populateCameraSelect();

    let device;
    if (state.facing === 'back') {
      device = findBackCamera(state.cameras);
      if (!device) {
        throw new AppError('초광각 카메라를 자동으로 찾지 못했습니다.\n오른쪽 위 ⚙︎ 설정에서 사용할 카메라를 직접 골라 주세요.');
      }
    } else {
      device = findFrontCamera(state.cameras);
    }
    state.device = device;
    // 이 앱의 후면 카메라는 초광각이므로 배율 표기는 0.5× 기준
    state.multiplier = state.facing === 'back' ? 0.5 : 1;

    const [w, h] = state.mode === 'photo' ? RES.photo[settings.photoRes] : RES.video[settings.videoRes];
    const video = { width: { ideal: w }, height: { ideal: h }, frameRate: { ideal: 30 } };
    if (device) video.deviceId = { exact: device.deviceId };
    else video.facingMode = 'user';
    state.videoConstraints = video;

    let stream;
    if (state.mode === 'video') {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video, audio: true });
      } catch (e) {
        if (e && (e.name === 'NotAllowedError' || e.name === 'NotFoundError')) {
          stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
          showToast('마이크 권한이 없어 소리 없이 녹화합니다.');
        } else {
          throw e;
        }
      }
    } else {
      stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
    }

    state.stream = stream;
    state.track = stream.getVideoTracks()[0];
    const track = state.track;
    track.addEventListener('ended', () => {
      // 시스템이 카메라를 끊은 경우에만 다시 연다 (stop() 으로 끈 경우에는 이벤트가 오지 않음)
      if (state.track === track && !document.hidden) startCamera();
    });
    els.video.srcObject = stream;
    await els.video.play().catch(() => {});
    await waitForVideoSize();

    if (state.mode === 'photo') await upgradePhotoResolution();

    const caps = state.track && state.track.getCapabilities ? state.track.getCapabilities() : {};
    state.hwZoom = caps && caps.zoom && caps.zoom.max > caps.zoom.min
      ? { min: caps.zoom.min, max: caps.zoom.max }
      : null;

    layoutStage();
    setZoom(state.desired[state.facing] || 1);
    updateFormatInfo();
    maybeShowPermissionTip();
  } catch (e) {
    if (e && e.name === 'OverconstrainedError' && settings.backDeviceId) {
      // 저장해 둔 카메라 ID 가 바뀐 경우
      settings.backDeviceId = null;
      saveSettings();
    }
    stopStream();
    showMessage(describeError(e));
  } finally {
    state.starting = false;
    if (state.restartQueued) {
      state.restartQueued = false;
      startCamera();
    }
  }
}

/** 가장 큰 4:3 영역의 넓이 */
function photoArea(w, h) {
  const long = Math.max(w, h);
  const short = Math.min(w, h);
  const cl = Math.min(long, (short * 4) / 3);
  return cl * ((cl * 3) / 4);
}

function waitForDimensionChange(oldW, oldH, timeout = 1500) {
  const v = els.video;
  return new Promise((resolve) => {
    const start = Date.now();
    const tick = () => {
      if ((v.videoWidth !== oldW || v.videoHeight !== oldH) || Date.now() - start > timeout) resolve();
      else setTimeout(tick, 50);
    };
    tick();
  });
}

/**
 * Safari 가 4:3 을 작게(예: 1920×1440) 줄 때가 있다.
 * 그럴 때는 4K(3840×2160)로 받아 가운데 4:3(2880×2160)만 쓰는 편이 화소가 더 많다.
 * 권한 창이 다시 뜨지 않도록 getUserMedia 대신 applyConstraints 로 바꿔 본다.
 */
async function upgradePhotoResolution() {
  const v = els.video;
  const track = state.track;
  if (!track || !track.applyConstraints) return;
  const before = photoArea(v.videoWidth, v.videoHeight);
  if (before >= 4032 * 3024 * 0.95) return;

  const prev = state.videoConstraints;
  const alt = Object.assign({}, prev, { width: { ideal: 3840 }, height: { ideal: 2160 } });
  let w = v.videoWidth;
  let h = v.videoHeight;
  try {
    await track.applyConstraints(alt);
    await waitForDimensionChange(w, h);
  } catch (_) {
    return;
  }
  if (photoArea(v.videoWidth, v.videoHeight) > before * 1.05) {
    state.videoConstraints = alt;
    return;
  }
  // 나아지지 않았으면 원래대로
  w = v.videoWidth;
  h = v.videoHeight;
  try {
    await track.applyConstraints(prev);
    await waitForDimensionChange(w, h);
  } catch (_) { /* 무시 */ }
}

function describeError(e) {
  if (e instanceof AppError) return e.message;
  switch (e && e.name) {
    case 'NotAllowedError':
      return '카메라 권한이 거부되었습니다.\n설정 앱 → 앱 → Safari → 카메라를 “허용”으로 바꾼 뒤 다시 시도해 주세요.';
    case 'NotFoundError':
      return '카메라를 찾을 수 없습니다.';
    case 'NotReadableError':
      return '카메라를 열 수 없습니다.\n다른 앱이 카메라를 쓰고 있거나 하드웨어 문제일 수 있습니다. 설정에서 다른 카메라를 골라 보세요.';
    case 'OverconstrainedError':
      return '선택한 카메라나 화질을 열 수 없습니다.\n설정에서 카메라와 화질을 다시 골라 주세요.';
    default:
      return '카메라 오류: ' + ((e && (e.message || e.name)) || String(e));
  }
}

function showMessage(text) {
  els.messageText.textContent = text;
  els.message.hidden = false;
}

function hideMessage() {
  els.message.hidden = true;
}

/**
 * 아이폰 카메라 앱처럼 미리보기를 화면 가로폭에 꽉 채운다.
 * - 4:3 / 1:1: 상단 바 바로 아래, 4:3 영역 안에 배치 (아래쪽 줌·모드 버튼은 미리보기 위에 겹침)
 * - 9:16 처럼 긴 화면: 화면 가운데에 두고 버튼들이 위에 겹친다
 */
function layoutStage() {
  const app = els.app.getBoundingClientRect();
  const W = app.width;
  const H = app.height;
  if (!W || !H) return;
  const base = baseRect();
  const ratio = base.bw && base.bh ? base.bh / base.bw : 4 / 3; // 세로/가로
  const top = els.topbar.getBoundingClientRect().bottom - app.top;
  const bottom = els.bottombar.getBoundingClientRect().top - app.top;
  const region = Math.min(W * (4 / 3), bottom - top); // 4:3 미리보기가 들어갈 자리

  const width = W;
  const height = W * ratio;
  let y;
  if (height <= region + 1) {
    y = top + (region - height) / 2;
  } else {
    // 화면보다 길면 가로를 꽉 채우고 위아래를 화면 밖으로 살짝 넘긴다 (좌우 여백 없음)
    y = (H - height) / 2;
  }
  els.stage.style.width = `${Math.round(width)}px`;
  els.stage.style.height = `${Math.round(height)}px`;
  els.stage.style.left = `${Math.round((W - width) / 2)}px`;
  els.stage.style.top = `${Math.round(y)}px`;
}

const ASPECTS = { '4:3': 4 / 3, '9:16': 16 / 9, '1:1': 1 };
const ASPECT_ORDER = ['4:3', '9:16', '1:1'];

function updateAspectButton() {
  els.btnAspect.textContent = settings.aspect;
  els.btnAspect.hidden = state.mode !== 'photo';
}

els.btnAspect.addEventListener('click', () => {
  const i = ASPECT_ORDER.indexOf(settings.aspect);
  settings.aspect = ASPECT_ORDER[(i + 1) % ASPECT_ORDER.length];
  saveSettings();
  updateAspectButton();
  layoutStage();
});

function updateFormatInfo() {
  const v = els.video;
  let name = '전면';
  if (state.facing === 'back') name = state.multiplier < 1 ? '초광각' : (state.device ? state.device.label : '후면');
  const s = state.track && state.track.getSettings ? state.track.getSettings() : {};
  const fps = s.frameRate ? ` · ${Math.round(s.frameRate)}fps` : '';
  const zoomKind = state.hwZoom ? 'HW줌' : 'SW줌';
  els.formatInfo.textContent = v.videoWidth ? `${name} · ${v.videoWidth}×${v.videoHeight}${fps} · ${zoomKind}` : '';
}

// ---------------------------------------------------------------- 줌

function zoomLimits() {
  const m = state.multiplier;
  if (state.hwZoom) return [state.hwZoom.min * m, Math.min(state.hwZoom.max, 10) * m];
  return [m, m * SW_MAX_FACTOR];
}

function zoomPresets() {
  const [, hi] = zoomLimits();
  const presets = state.multiplier < 1 ? [0.5, 1] : [1, 2];
  return presets.filter((p) => p <= hi + 0.001);
}

function zoomText(value) {
  const r = Math.round(value * 10) / 10;
  let s = Number.isInteger(r) ? String(r) : r.toFixed(1);
  return s + '×';
}

let hwPending = null;
let hwBusy = false;

function requestHwZoom(factor) {
  hwPending = factor;
  if (hwBusy) return;
  hwBusy = true;
  (async () => {
    while (hwPending !== null) {
      const value = hwPending;
      hwPending = null;
      const track = state.track;
      if (!track) break;
      try {
        await track.applyConstraints(Object.assign({}, state.videoConstraints, { advanced: [{ zoom: value }] }));
      } catch (_) { /* 무시 */ }
    }
    hwBusy = false;
  })();
}

function setZoom(display) {
  if (state.zoomLocked) return;
  const [lo, hi] = zoomLimits();
  const value = Math.min(Math.max(display, lo), hi);
  state.zoom = value;
  state.desired[state.facing] = value;
  const factor = value / state.multiplier;
  if (state.hwZoom) {
    state.swFactor = 1;
    requestHwZoom(factor);
  } else {
    state.swFactor = factor;
  }
  applyPreviewTransform();
  renderZoomBar();
}

function applyPreviewTransform() {
  const s = state.swFactor;
  const mirror = state.facing === 'front' ? -1 : 1;
  els.video.style.transform = `scale(${s * mirror}, ${s})`;
}

function renderZoomBar() {
  const presets = zoomPresets();
  const active = presets.filter((p) => p <= state.zoom + 0.01).pop() || presets[0];
  els.zoombar.innerHTML = '';
  for (const p of presets) {
    const b = document.createElement('button');
    const isActive = p === active;
    b.className = isActive ? 'active' : '';
    b.textContent = zoomText(isActive ? state.zoom : p);
    b.disabled = state.zoomLocked;
    b.addEventListener('click', () => setZoom(p));
    els.zoombar.appendChild(b);
  }
}

// 두 손가락 확대/축소
let pinch = null;

function touchDistance(touches) {
  const dx = touches[0].clientX - touches[1].clientX;
  const dy = touches[0].clientY - touches[1].clientY;
  return Math.hypot(dx, dy);
}

els.stage.addEventListener('touchstart', (e) => {
  if (e.touches.length === 2) {
    pinch = { distance: touchDistance(e.touches), zoom: state.zoom };
    e.preventDefault();
  }
}, { passive: false });

els.stage.addEventListener('touchmove', (e) => {
  if (pinch && e.touches.length === 2) {
    setZoom(pinch.zoom * (touchDistance(e.touches) / pinch.distance));
    e.preventDefault();
  }
}, { passive: false });

els.stage.addEventListener('touchend', (e) => {
  if (e.touches.length < 2) pinch = null;
});

// 페이지 자체 확대 방지
document.addEventListener('gesturestart', (e) => e.preventDefault());
document.addEventListener('dblclick', (e) => e.preventDefault(), { passive: false });

// ---------------------------------------------------------------- 사진

function makeThumb(source, sx, sy, sw, sh) {
  const max = 240;
  const scale = max / Math.max(sw, sh);
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(sw * scale));
  c.height = Math.max(1, Math.round(sh * scale));
  c.getContext('2d').drawImage(source, sx, sy, sw, sh, 0, 0, c.width, c.height);
  return c.toDataURL('image/jpeg', 0.7);
}

/** 줌을 빼고, 결과물로 쓸 영역 (사진 모드는 4:3, 동영상 모드는 스트림 그대로) */
function baseRect() {
  const v = els.video;
  const w = v.videoWidth;
  const h = v.videoHeight;
  let bw = w;
  let bh = h;
  if (state.mode === 'photo' && w && h) {
    const longShort = ASPECTS[settings.aspect] || 4 / 3;
    const ratio = h > w ? 1 / longShort : longShort; // 가로/세로
    if (w / h > ratio) bw = Math.round(h * ratio);
    else bh = Math.round(w / ratio);
  }
  return { w, h, bw, bh };
}

function cropRect() {
  const { w, h, bw, bh } = baseRect();
  const f = state.swFactor;
  const cw = Math.round(bw / f);
  const ch = Math.round(bh / f);
  return { w, h, bw, bh, sx: Math.round((w - cw) / 2), sy: Math.round((h - ch) / 2), cw, ch };
}

/**
 * 결과물 크기: 소프트웨어 줌으로 잘라낸 경우 최대 2배까지 고품질로 키운다. (긴 변 최대 4032)
 */
function outputSize(r) {
  const up = Math.max(1, Math.min(state.swFactor, 2, 4032 / Math.max(r.cw, r.ch)));
  return { ow: Math.round(r.cw * up), oh: Math.round(r.ch * up), upscaled: up > 1.01 };
}

/** 3×3 언샤프 마스크. 키운 이미지의 흐릿함을 줄인다. */
function sharpen(ctx, w, h, amount) {
  const img = ctx.getImageData(0, 0, w, h);
  const px = img.data;
  const stride = w * 4;
  let prevRow = px.slice(0, stride);
  for (let y = 1; y < h - 1; y++) {
    const off = y * stride;
    const curRow = px.slice(off, off + stride);
    const next = off + stride;
    for (let x = 4; x < stride - 4; x++) {
      if ((x & 3) === 3) continue; // 알파
      const c = curRow[x];
      const lap = 4 * c - curRow[x - 4] - curRow[x + 4] - prevRow[x] - px[next + x];
      px[off + x] = c + amount * lap;
    }
    prevRow = curRow;
  }
  ctx.putImageData(img, 0, 0);
}

/** 현재 프레임을 결과물 캔버스에 그린다 (자르기 + 확대 + 선명도) */
function renderPhoto(c) {
  const v = els.video;
  const r = cropRect();
  const { ow, oh, upscaled } = outputSize(r);
  c.width = ow;
  c.height = oh;
  const ctx = c.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(v, r.sx, r.sy, r.cw, r.ch, 0, 0, ow, oh);
  if (settings.sharpen) {
    try { sharpen(ctx, ow, oh, upscaled ? 0.45 : 0.2); } catch (_) { /* 메모리 부족 등: 보정 없이 저장 */ }
  }
  return { ow, oh, ctx };
}

async function capturePhoto() {
  const v = els.video;
  if (!state.stream || !v.videoWidth) return;
  playSound('shutter');
  flashScreen();

  const c = els.canvas;
  const { ow, oh } = renderPhoto(c);
  const thumb = makeThumb(c, 0, 0, ow, oh);
  const label = `사진 ${ow}×${oh}`;

  if (settings.autoSave && canShareFiles()) {
    // iOS 는 탭 이벤트가 살아 있는 동안에만 공유 시트를 열 수 있으므로, 기다리지 않고(동기) 바로 만든다.
    let blob = null;
    try {
      blob = dataUrlToBlob(c.toDataURL('image/jpeg', 0.95));
    } catch (_) { /* 아래에서 처리 */ }
    c.width = 1;
    c.height = 1;
    if (!blob || !blob.size) {
      showToast('사진을 만들지 못했습니다.');
      return;
    }
    autoSaveItem(addItem('photo', blob, 'jpg', thumb), label);
    return;
  }

  const blob = await new Promise((resolve) => c.toBlob(resolve, 'image/jpeg', 0.95));
  c.width = 1;
  c.height = 1;
  if (!blob) {
    showToast('사진을 만들지 못했습니다.');
    return;
  }
  showToast(label, addItem('photo', blob, 'jpg', thumb));
}

function flashScreen() {
  els.flash.className = 'on';
  requestAnimationFrame(() => requestAnimationFrame(() => { els.flash.className = 'off'; }));
}

// ---------------------------------------------------------------- 동영상

function pickMime() {
  if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) return '';
  const candidates = [
    'video/mp4;codecs=avc1.640028,mp4a.40.2',
    'video/mp4;codecs=avc1,mp4a',
    'video/mp4',
    'video/webm;codecs=vp9,opus',
    'video/webm',
  ];
  return candidates.find((t) => MediaRecorder.isTypeSupported(t)) || '';
}

function startRecording() {
  if (!window.MediaRecorder) {
    alert('이 브라우저는 동영상 녹화를 지원하지 않습니다. iOS를 최신 버전으로 업데이트해 주세요.');
    return;
  }
  const v = els.video;
  if (!state.stream || !v.videoWidth) return;

  let recStream = state.stream;
  const startRect = cropRect();
  const thumb = makeThumb(v, startRect.sx, startRect.sy, startRect.cw, startRect.ch);
  const startedAt = Date.now();

  if (!state.hwZoom) {
    if (state.swFactor > 1.001) {
      // 소프트웨어 줌: 잘라낸 화면을 캔버스에 그려서 녹화 (녹화 중에도 확대/축소 가능)
      const { bw: w, bh: h } = baseRect();
      const scale = Math.min(1, 1920 / Math.max(w, h));
      const c = document.createElement('canvas');
      c.width = Math.round((w * scale) / 2) * 2;
      c.height = Math.round((h * scale) / 2) * 2;
      const ctx = c.getContext('2d');
      ctx.imageSmoothingQuality = 'high';
      const draw = () => {
        const r = cropRect();
        ctx.drawImage(v, r.sx, r.sy, r.cw, r.ch, 0, 0, c.width, c.height);
        state.recLoop = requestAnimationFrame(draw);
      };
      draw();
      state.recCanvasStream = c.captureStream(30);
      recStream = new MediaStream([
        ...state.recCanvasStream.getVideoTracks(),
        ...state.stream.getAudioTracks(),
      ]);
    } else {
      // 원본 스트림을 그대로 녹화 (최고 화질). 녹화 중에는 배율 고정.
      state.zoomLocked = true;
      renderZoomBar();
    }
  }

  const mime = pickMime();
  const options = { videoBitsPerSecond: BITRATE[settings.videoRes] || 12e6, audioBitsPerSecond: 128000 };
  if (mime) options.mimeType = mime;

  let recorder;
  try {
    recorder = new MediaRecorder(recStream, options);
  } catch (_) {
    try {
      recorder = new MediaRecorder(recStream);
    } catch (e) {
      cleanupRecording();
      alert('녹화를 시작할 수 없습니다: ' + (e && e.message ? e.message : e));
      return;
    }
  }

  const chunks = [];
  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size) chunks.push(e.data);
  };
  recorder.onstop = () => {
    cleanupRecording();
    const type = recorder.mimeType || mime || 'video/mp4';
    const blob = new Blob(chunks, { type });
    if (!blob.size) {
      showToast('녹화된 내용이 없습니다.');
      return;
    }
    const ext = type.includes('webm') ? 'webm' : 'mp4';
    const item = addItem('video', blob, ext, thumb);
    autoSaveItem(item, `동영상 ${formatTime((Date.now() - startedAt) / 1000)}`);
  };
  recorder.onerror = (e) => {
    showToast('녹화 오류: ' + (e && e.error ? e.error.message : ''));
  };

  recorder.start(1000);
  state.recorder = recorder;
  state.recStart = Date.now();
  playSound('start');
  setRecordingUI(true);
  state.recTimer = setInterval(updateRecTime, 500);
  updateRecTime();
}

function stopRecording() {
  const recorder = state.recorder;
  state.recorder = null;
  clearInterval(state.recTimer);
  state.recTimer = null;
  setRecordingUI(false);
  if (recorder && recorder.state !== 'inactive') {
    playSound('stop');
    recorder.stop();
  } else {
    cleanupRecording();
  }
}

function cleanupRecording() {
  if (state.recLoop) cancelAnimationFrame(state.recLoop);
  state.recLoop = null;
  if (state.recCanvasStream) state.recCanvasStream.getTracks().forEach((t) => t.stop());
  state.recCanvasStream = null;
  state.zoomLocked = false;
  renderZoomBar();
}

function formatTime(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

function updateRecTime() {
  els.recTime.textContent = formatTime((Date.now() - state.recStart) / 1000);
}

function setRecordingUI(on) {
  document.body.classList.toggle('recording', on);
  els.recTime.hidden = !on;
  els.formatInfo.hidden = on;
  els.btnFlip.disabled = on;
  els.btnSettings.disabled = on;
  els.btnGallery.disabled = on;
  for (const b of els.modes.querySelectorAll('button')) b.disabled = on;
}

// ---------------------------------------------------------------- 소리

function playSound(kind) {
  if (!settings.sound) return;
  try {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    const ctx = state.audioCtx || (state.audioCtx = new AC());
    if (ctx.state === 'suspended') ctx.resume();
    const t = ctx.currentTime;
    if (kind === 'shutter') {
      const len = Math.floor(ctx.sampleRate * 0.09);
      const buffer = ctx.createBuffer(1, len, ctx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < len; i++) {
        const env = i < len * 0.15 ? 1 : Math.pow(1 - (i - len * 0.15) / (len * 0.85), 3);
        data[i] = (Math.random() * 2 - 1) * env * 0.6;
      }
      const src = ctx.createBufferSource();
      src.buffer = buffer;
      const filter = ctx.createBiquadFilter();
      filter.type = 'bandpass';
      filter.frequency.value = 2500;
      src.connect(filter).connect(ctx.destination);
      src.start(t);
    } else {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = kind === 'start' ? 880 : 660;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.25, t + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.15);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + 0.16);
    }
  } catch (_) { /* 무시 */ }
}

// ---------------------------------------------------------------- 토스트 / 미리보기

function showToast(text, item) {
  clearTimeout(state.toastTimer);
  els.toastText.textContent = text;
  state.toastItem = item || null;
  els.toastSave.hidden = !item;
  els.toast.hidden = false;
  state.toastTimer = setTimeout(() => {
    els.toast.hidden = true;
    state.toastItem = null;
  }, item ? 4500 : 3000);
}

els.toastSave.addEventListener('click', async () => {
  const item = state.toastItem;
  els.toast.hidden = true;
  state.toastItem = null;
  if (item) await shareItems([item]);
});

function updateThumb() {
  const last = state.items[state.items.length - 1];
  if (last && last.thumb) {
    els.thumbImg.src = last.thumb;
    els.thumbImg.hidden = false;
  } else {
    els.thumbImg.removeAttribute('src');
    els.thumbImg.hidden = true;
  }
  const unsaved = state.items.filter((it) => !it.saved).length;
  els.badge.textContent = String(unsaved);
  els.badge.hidden = unsaved === 0;
}

// ---------------------------------------------------------------- 시트 (갤러리 / 보기 / 설정)

function openSheet(sheet) {
  sheet.hidden = false;
}

function closeSheet(sheet) {
  sheet.hidden = true;
  if (sheet === els.viewer) closeViewer();
}

document.querySelectorAll('[data-close]').forEach((btn) => {
  btn.addEventListener('click', () => closeSheet(document.getElementById(btn.dataset.close)));
});

function renderGallery() {
  els.galleryGrid.innerHTML = '';
  const items = [...state.items].reverse();
  for (const item of items) {
    const cell = document.createElement('button');
    cell.className = 'cell';
    const img = document.createElement('img');
    if (item.thumb) img.src = item.thumb;
    img.alt = '';
    cell.appendChild(img);
    if (item.type === 'video') {
      const tag = document.createElement('span');
      tag.className = 'tag';
      tag.textContent = '동영상';
      cell.appendChild(tag);
    }
    if (item.saved) {
      const ok = document.createElement('span');
      ok.className = 'saved';
      ok.textContent = '✓';
      cell.appendChild(ok);
    }
    cell.addEventListener('click', () => openViewer(item));
    els.galleryGrid.appendChild(cell);
  }
  els.galleryEmpty.hidden = items.length > 0;
  const unsaved = state.items.filter((it) => !it.saved).length;
  els.btnSaveAll.disabled = state.items.length === 0;
  els.btnSaveAll.textContent = unsaved > 0 && unsaved < state.items.length
    ? `저장 안 한 ${unsaved}개 사진 앱에 저장`
    : '전부 사진 앱에 저장';
}

els.btnGallery.addEventListener('click', () => {
  renderGallery();
  openSheet(els.gallery);
});

els.btnSaveAll.addEventListener('click', async () => {
  const unsaved = state.items.filter((it) => !it.saved);
  await shareItems(unsaved.length ? unsaved : state.items);
});

els.btnClear.addEventListener('click', async () => {
  if (!state.items.length) return;
  const unsaved = state.items.filter((it) => !it.saved).length;
  const msg = unsaved
    ? `사진 앱에 저장하지 않은 항목이 ${unsaved}개 있습니다. 그래도 모두 삭제할까요?`
    : '앱 안의 임시 보관함을 비울까요? (사진 앱에 저장한 것은 그대로 남습니다)';
  if (!confirm(msg)) return;
  state.items = [];
  if (state.dbOk) {
    try { await db.clear(); } catch (_) { /* 무시 */ }
  }
  updateThumb();
  renderGallery();
});

function openViewer(item) {
  closeViewer();
  state.viewerItem = item;
  state.viewerUrl = URL.createObjectURL(item.blob);
  els.viewerBody.innerHTML = '';
  let media;
  if (item.type === 'photo') {
    media = document.createElement('img');
  } else {
    media = document.createElement('video');
    media.controls = true;
    media.playsInline = true;
    media.setAttribute('playsinline', '');
  }
  media.src = state.viewerUrl;
  els.viewerBody.appendChild(media);
  const d = new Date(item.created);
  els.viewerTitle.textContent = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
  els.viewerSave.textContent = item.saved ? '다시 저장 / 공유' : '사진 앱에 저장';
  openSheet(els.viewer);
}

function closeViewer() {
  els.viewerBody.innerHTML = '';
  if (state.viewerUrl) URL.revokeObjectURL(state.viewerUrl);
  state.viewerUrl = null;
  state.viewerItem = null;
}

els.viewerSave.addEventListener('click', async () => {
  const item = state.viewerItem;
  if (!item) return;
  if (await shareItems([item])) {
    els.viewerSave.textContent = '다시 저장 / 공유';
  }
});

els.viewerDelete.addEventListener('click', async () => {
  const item = state.viewerItem;
  if (!item) return;
  if (!item.saved && !confirm('사진 앱에 저장하지 않았습니다. 삭제할까요?')) return;
  await removeItem(item);
  closeSheet(els.viewer);
  renderGallery();
});

// 설정

function cameraLabel(c, i) {
  return c.label || `카메라 ${i + 1}`;
}

function populateCameraSelect() {
  els.setCamera.innerHTML = '';
  const backId = (findBackCamera(state.cameras) || {}).deviceId;
  state.cameras.forEach((c, i) => {
    if (FRONT_RE.test(c.label)) return;
    const opt = document.createElement('option');
    opt.value = c.deviceId;
    let label = cameraLabel(c, i);
    if (UW_RE.test(c.label) && !MULTI_RE.test(c.label)) label += ' ✅';
    opt.textContent = label;
    if (c.deviceId === backId) opt.selected = true;
    els.setCamera.appendChild(opt);
  });
  if (!backId) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '선택하세요';
    opt.selected = true;
    els.setCamera.prepend(opt);
  }
}

function syncSettingsForm() {
  els.setPhotoRes.value = settings.photoRes;
  els.setVideoRes.value = settings.videoRes;
  els.setGrid.checked = settings.grid;
  els.setSound.checked = settings.sound;
  els.setAutoSave.checked = settings.autoSave;
  els.setSharpen.checked = settings.sharpen;
  els.grid.hidden = !settings.grid;
}

els.btnSettings.addEventListener('click', () => {
  syncSettingsForm();
  els.diag.textContent = diagnostics();
  openSheet(els.settings);
});

els.setCamera.addEventListener('change', () => {
  const cam = state.cameras.find((c) => c.deviceId === els.setCamera.value);
  if (!cam) return;
  settings.backDeviceId = cam.deviceId;
  settings.backLabel = cam.label;
  saveSettings();
  state.desired.back = 1;
  if (state.facing === 'back') startCamera();
});

els.setPhotoRes.addEventListener('change', () => {
  settings.photoRes = els.setPhotoRes.value;
  saveSettings();
  if (state.mode === 'photo') startCamera();
});

els.setVideoRes.addEventListener('change', () => {
  settings.videoRes = els.setVideoRes.value;
  saveSettings();
  if (state.mode === 'video') startCamera();
});

els.setGrid.addEventListener('change', () => {
  settings.grid = els.setGrid.checked;
  els.grid.hidden = !settings.grid;
  saveSettings();
});

els.setSharpen.addEventListener('change', () => {
  settings.sharpen = els.setSharpen.checked;
  saveSettings();
});

els.setAutoSave.addEventListener('change', () => {
  settings.autoSave = els.setAutoSave.checked;
  saveSettings();
});

els.setSound.addEventListener('change', () => {
  settings.sound = els.setSound.checked;
  saveSettings();
});

els.btnRescan.addEventListener('click', () => {
  settings.backDeviceId = null;
  settings.backLabel = null;
  saveSettings();
  closeSheet(els.settings);
  startCamera();
});

els.btnCopyDiag.addEventListener('click', async () => {
  const text = diagnostics();
  try {
    await navigator.clipboard.writeText(text);
    els.btnCopyDiag.textContent = '복사했습니다';
  } catch (_) {
    els.btnCopyDiag.textContent = '복사 실패 (길게 눌러 직접 복사하세요)';
  }
  setTimeout(() => { els.btnCopyDiag.textContent = '진단 정보 복사'; }, 2000);
});

function diagnostics() {
  const lines = [];
  lines.push(`UA: ${navigator.userAgent}`);
  lines.push(`홈 화면 앱: ${window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true}`);
  lines.push('');
  lines.push('[카메라 목록]');
  state.cameras.forEach((c, i) => {
    const mark = state.device && c.deviceId === state.device.deviceId ? ' ← 사용 중' : '';
    lines.push(`${i + 1}. ${c.label || '(이름 없음)'}${mark}`);
  });
  lines.push('');
  lines.push('[현재 스트림]');
  if (state.track) {
    const s = state.track.getSettings ? state.track.getSettings() : {};
    lines.push(`해상도: ${els.video.videoWidth}×${els.video.videoHeight}  fps: ${s.frameRate || '?'}`);
    lines.push(`배율 기준: ${state.multiplier}  현재: ${zoomText(state.zoom)}  ${state.hwZoom ? `하드웨어 줌 ${state.hwZoom.min}~${state.hwZoom.max}` : `소프트웨어 줌 ×${state.swFactor.toFixed(2)}`}`);
    try {
      const caps = state.track.getCapabilities ? state.track.getCapabilities() : null;
      if (caps) {
        const pick = {};
        ['width', 'height', 'frameRate', 'zoom', 'facingMode', 'torch'].forEach((k) => { if (caps[k] !== undefined) pick[k] = caps[k]; });
        lines.push(`capabilities: ${JSON.stringify(pick)}`);
      }
    } catch (_) { /* 무시 */ }
  } else {
    lines.push('(꺼짐)');
  }
  lines.push('');
  lines.push(`녹화 형식: ${pickMime() || '(MediaRecorder 없음)'}`);
  lines.push(`공유(파일): ${!!(navigator.canShare && navigator.canShare({ files: [new File([''], 'a.jpg', { type: 'image/jpeg' })] }))}`);
  lines.push(`임시 보관함: ${state.dbOk ? 'IndexedDB' : '메모리'} · ${state.items.length}개`);
  return lines.join('\n');
}

// ---------------------------------------------------------------- 조작

els.modes.querySelectorAll('button').forEach((btn) => {
  btn.addEventListener('click', () => {
    if (state.recorder) return;
    const mode = btn.dataset.mode;
    if (mode === state.mode) return;
    state.mode = mode;
    document.body.classList.toggle('mode-video', mode === 'video');
    updateAspectButton();
    els.modes.querySelectorAll('button').forEach((b) => b.classList.toggle('active', b === btn));
    startCamera();
  });
});

els.btnShutter.addEventListener('click', () => {
  if (state.mode === 'photo') {
    capturePhoto();
  } else if (state.recorder) {
    stopRecording();
  } else {
    startRecording();
  }
});

els.btnFlip.addEventListener('click', () => {
  if (state.recorder) return;
  state.facing = state.facing === 'back' ? 'front' : 'back';
  startCamera();
});

els.btnStart.addEventListener('click', () => startCamera());

window.addEventListener('resize', layoutStage);
els.video.addEventListener('resize', () => {
  layoutStage();
  updateFormatInfo();
});

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (state.recorder) stopRecording();
    // 스트림은 끄지 않는다. 다시 돌아왔을 때 getUserMedia 를 새로 부르지 않아야 권한 창이 덜 뜬다.
  } else if (!state.stream || !state.track || state.track.readyState === 'ended') {
    startCamera();
  } else {
    els.video.play().catch(() => {});
  }
});

// ---------------------------------------------------------------- 권한 안내

const TIP_KEY = 'rearcam.permissionTipDismissed';

function maybeShowPermissionTip() {
  let dismissed = false;
  try { dismissed = localStorage.getItem(TIP_KEY) === '1'; } catch (_) { /* 무시 */ }
  if (!dismissed) els.tip.hidden = false;
}

els.tipClose.addEventListener('click', () => {
  els.tip.hidden = true;
  try { localStorage.setItem(TIP_KEY, '1'); } catch (_) { /* 무시 */ }
});

// ---------------------------------------------------------------- 시작

if (!ASPECTS[settings.aspect]) settings.aspect = '4:3';
updateAspectButton();
syncSettingsForm();
renderZoomBar();
loadItems();
startCamera();
