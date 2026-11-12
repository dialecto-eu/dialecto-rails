(() => {
  // js/in_context/protocol.js
  var SOURCE = "dialecto";
  var VERSION = 1;
  var MAX_STRING = 2e4;
  var MAX_EDITS = 5e3;
  var MAX_FORMS = 10;
  var isString = (value) => typeof value === "string" && value.length <= MAX_STRING;
  var isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  var identity = (m) => isString(m.domain) && isString(m.key) && isString(m.locale) && m.key !== "";
  function gettextFields(raw) {
    if (raw.forms === void 0) return {};
    const { forms, msgid_plural: plural = null, from_forms: fromForms } = raw;
    const listOk = (list) => Array.isArray(list) && list.length > 0 && list.length <= MAX_FORMS && list.every(isString);
    if (!listOk(forms) || !(plural === null || isString(plural))) return null;
    if (fromForms !== void 0 && !listOk(fromForms)) return null;
    return { forms: [...forms], msgid_plural: plural, ...fromForms === void 0 ? {} : { from_forms: [...fromForms] } };
  }
  function normalizeEdit(raw) {
    if (!isPlainObject(raw) || !identity(raw) || !isString(raw.from) || !isString(raw.to)) return null;
    const gettext = gettextFields(raw);
    if (!gettext) return null;
    return { domain: raw.domain, key: raw.key, locale: raw.locale, from: raw.from, to: raw.to, ...gettext };
  }
  function normalizeEdits(list) {
    if (!Array.isArray(list) || list.length > MAX_EDITS) return null;
    const edits = [];
    for (const item of list) {
      const edit = normalizeEdit(item);
      if (!edit) return null;
      edits.push(edit);
    }
    return edits;
  }
  function parseIncoming(data) {
    if (!isPlainObject(data) || data.source !== SOURCE || data.v !== VERSION || typeof data.type !== "string") {
      return null;
    }
    switch (data.type) {
      case "ready": {
        const edits = data.edits === void 0 ? [] : normalizeEdits(data.edits);
        if (!edits) return null;
        return { type: "ready", signed_in: data.signed_in === true, edits };
      }
      case "preview": {
        const edit = normalizeEdit(data);
        return edit ? { type: "preview", ...edit } : null;
      }
      case "preview_clear":
        return identity(data) ? { type: "preview_clear", domain: data.domain, key: data.key, locale: data.locale } : null;
      case "previews_reset": {
        const edits = normalizeEdits(data.edits);
        return edits ? { type: "previews_reset", edits } : null;
      }
      case "highlight":
        if (data.domain === null) return { type: "highlight", domain: null, key: null, scroll: false };
        if (!isString(data.domain) || !isString(data.key) || data.key === "") return null;
        return { type: "highlight", domain: data.domain, key: data.key, scroll: data.scroll === true };
      case "pick_mode":
        return typeof data.on === "boolean" ? { type: "pick_mode", on: data.on } : null;
      case "save_files": {
        const edits = normalizeEdits(data.edits);
        return edits && edits.length > 0 && edits.every((edit) => edit.forms === void 0) ? { type: "save_files", edits: edits.map(({ domain, key, locale, from, to }) => ({ domain, key, locale, from, to })) } : null;
      }
      // The account's shortcut for this user ("" = none); the overlay judges whether it is usable.
      case "shortcut":
        return isString(data.key) ? { type: "shortcut", key: data.key } : null;
      case "close":
      case "reload":
      case "toggle":
        return { type: data.type };
      default:
        return null;
    }
  }
  var envelope = (type, payload = {}) => ({ source: SOURCE, v: VERSION, type, ...payload });
  var hello = (page, site, toggleKey = "", baseKey = "") => envelope("hello", {
    page,
    site,
    ...toggleKey ? { toggle_key: toggleKey } : {},
    ...baseKey && baseKey !== toggleKey ? { base_key: baseKey } : {}
  });
  var pageStrings = (strings) => envelope("page_strings", { strings });
  var pick = (domain, key) => envelope("pick", { domain, key });
  var refOf = (ref) => ({ domain: ref.domain, key: ref.key, locale: ref.locale });
  function filesSaved(result) {
    if (!isPlainObject(result) || !Array.isArray(result.saved)) {
      return envelope("files_saved", { error: typeof result?.error === "string" ? result.error : "unreachable" });
    }
    const refs = (list) => Array.isArray(list) ? list.filter((ref) => isPlainObject(ref) && identity(ref)).slice(0, MAX_EDITS) : [];
    return envelope("files_saved", {
      saved: refs(result.saved).map(refOf),
      refused: refs(result.refused).map((ref) => ({ ...refOf(ref), reason: isString(ref.reason) ? ref.reason : "refused" })),
      files: Array.isArray(result.files) ? result.files.filter(isString).slice(0, 100) : [],
      scanned: result.scan?.ok === true
    });
  }
  var previewStatus = ({ domain, key, locale, applied, unsupported, reason, text: text3 }) => envelope("preview_status", {
    domain,
    key,
    locale,
    applied,
    unsupported,
    ...reason ? { reason } : {},
    ...typeof text3 === "string" ? { text: text3 } : {}
  });

  // js/in_context/bridge.js
  var HELLO_INTERVAL_MS = 500;
  var HELLO_ATTEMPTS = 20;
  var SNAPSHOT_DEBOUNCE_MS = 150;
  function createBridge({ origin, frameWindow, page, site, strings, onMessage, onTimeout, toggleKey = () => "", baseKey = () => "" }) {
    let ready = false;
    let helloTimer = 0;
    let attempts = 0;
    let snapshotTimer = 0;
    let lastSnapshot = null;
    const post = (message) => {
      const target = frameWindow();
      if (target) target.postMessage(message, origin);
    };
    function sendSnapshot(force) {
      if (!ready) return;
      const rows = strings();
      const serialized = JSON.stringify(rows);
      if (!force && serialized === lastSnapshot) return;
      lastSnapshot = serialized;
      post(pageStrings(rows));
    }
    function stopHandshake() {
      clearInterval(helloTimer);
      helloTimer = 0;
    }
    function handle(event) {
      if (event.origin !== origin || !event.source || event.source !== frameWindow()) return;
      const message = parseIncoming(event.data);
      if (!message) return;
      if (message.type === "ready") {
        ready = true;
        stopHandshake();
        sendSnapshot(true);
      }
      onMessage(message);
    }
    window.addEventListener("message", handle);
    return {
      /** Send `hello` now and every 500ms until `ready` (about 10s). */
      startHandshake() {
        stopHandshake();
        ready = false;
        lastSnapshot = null;
        attempts = 0;
        const tick = () => {
          if (ready) return;
          if (attempts >= HELLO_ATTEMPTS) {
            stopHandshake();
            onTimeout();
            return;
          }
          attempts += 1;
          post(hello(page(), site(), toggleKey(), baseKey()));
        };
        helloTimer = setInterval(tick, HELLO_INTERVAL_MS);
        tick();
      },
      /** Debounced, de-duplicated `page_strings`. */
      requestSnapshot() {
        if (!ready) return;
        clearTimeout(snapshotTimer);
        snapshotTimer = setTimeout(() => sendSnapshot(false), SNAPSHOT_DEBOUNCE_MS);
      },
      sendPick: (domain, key) => post(pick(domain, key)),
      sendPreviewStatus: (status) => post(previewStatus(status)),
      sendFilesSaved: (result) => post(filesSaved(result)),
      isReady: () => ready,
      destroy() {
        stopHandshake();
        clearTimeout(snapshotTimer);
        window.removeEventListener("message", handle);
      }
    };
  }

  // js/in_context/codec.js
  var OPEN = String.fromCodePoint(8290);
  var HEADER_END = String.fromCodePoint(8291);
  var CLOSE = String.fromCodePoint(8292);
  var DIGITS = [8204, 8205, 8288, 8289].map((cp) => String.fromCodePoint(cp));
  var FIELD_SEP = String.fromCodePoint(31);
  var RECORD_SEP = String.fromCodePoint(30);
  var DIGIT_VALUE = new Map(DIGITS.map((char, value) => [char, value]));
  var encoder = new TextEncoder();
  var decoder = new TextDecoder("utf-8", { fatal: true });
  function readArgs(json) {
    if (json === null) return null;
    try {
      const args = JSON.parse(json);
      return args !== null && typeof args === "object" && !Array.isArray(args) ? args : null;
    } catch {
      return null;
    }
  }
  function readHeader(str, at) {
    let i = at + 1;
    const bytes = [];
    let acc = 0;
    let count = 0;
    for (; i < str.length; i++) {
      const value = DIGIT_VALUE.get(str[i]);
      if (value === void 0) break;
      acc = acc << 2 | value;
      count++;
      if (count % 4 === 0) {
        bytes.push(acc);
        acc = 0;
      }
    }
    if (str[i] !== HEADER_END || count === 0 || count % 4 !== 0) return null;
    let payload;
    try {
      payload = decoder.decode(Uint8Array.from(bytes));
    } catch {
      return null;
    }
    const record = payload.lastIndexOf(RECORD_SEP);
    const identity2 = record < 0 ? payload : payload.slice(0, record);
    const first = identity2.indexOf(FIELD_SEP);
    const last = identity2.lastIndexOf(FIELD_SEP);
    if (first < 0 || first === last) return null;
    return {
      domain: identity2.slice(0, first),
      key: identity2.slice(first + 1, last),
      locale: identity2.slice(last + 1),
      args: readArgs(record < 0 ? null : payload.slice(record + 1)),
      next: i + 1
    };
  }
  function parseSegments(str) {
    const roots = [];
    const stack = [];
    const attach = (segment) => {
      (stack.length ? stack[stack.length - 1].children : roots).push(segment);
    };
    for (let i = 0; i < str.length; i++) {
      const char = str[i];
      if (char === OPEN) {
        const header = readHeader(str, i);
        if (!header) continue;
        stack.push({
          domain: header.domain,
          key: header.key,
          locale: header.locale,
          args: header.args,
          start: i,
          innerStart: header.next,
          innerEnd: str.length,
          end: str.length,
          open: true,
          children: []
        });
        i = header.next - 1;
      } else if (char === CLOSE && stack.length) {
        const segment = stack.pop();
        segment.innerEnd = i;
        segment.end = i + 1;
        segment.open = false;
        attach(segment);
      }
    }
    while (stack.length) attach(stack.pop());
    return roots;
  }
  function flattenSegments(segments) {
    const out = [];
    const visit = (list) => {
      for (const segment of list) {
        out.push(segment);
        visit(segment.children);
      }
    };
    visit(segments);
    return out;
  }
  function stripMarks(str) {
    if (!str || str.indexOf(OPEN) < 0 && str.indexOf(CLOSE) < 0 && str.indexOf(HEADER_END) < 0) return str ?? "";
    let out = "";
    for (let i = 0; i < str.length; i++) {
      const char = str[i];
      if (char === OPEN) {
        const header = readHeader(str, i);
        if (header) i = header.next - 1;
      } else if (char !== CLOSE && char !== HEADER_END) {
        out += char;
      }
    }
    return out;
  }
  function hasMarks(str) {
    return typeof str === "string" && str.indexOf(OPEN) >= 0;
  }
  var KEY_SEP = String.fromCodePoint(9247);
  var keyId = (domain, key, locale) => domain + KEY_SEP + key + KEY_SEP + locale;
  var CONTEXT_SEP = String.fromCodePoint(4);
  function splitKey(key) {
    const at = key.indexOf(CONTEXT_SEP);
    return at < 0 ? { msgctxt: null, msgid: key } : { msgctxt: key.slice(0, at), msgid: key.slice(at + 1) };
  }
  function segmentText(str, segment) {
    return stripMarks(str.slice(segment.innerStart, segment.innerEnd));
  }

  // js/in_context/controls.js
  var LABEL_INPUTS = /* @__PURE__ */ new Set(["button", "submit", "reset", "image"]);
  function isDataControl(el) {
    if (el.localName === "textarea") return true;
    return el.localName === "input" && !LABEL_INPUTS.has(String(el.type || "text").toLowerCase());
  }
  function markedStrings(value) {
    return flattenSegments(parseSegments(value)).map((segment) => ({
      domain: segment.domain,
      key: segment.key,
      locale: segment.locale,
      segment,
      text: segmentText(value, segment)
    }));
  }
  function stripFormData(formData) {
    const entries = [...formData.entries()];
    if (!entries.some(([, value]) => typeof value === "string" && stripMarks(value) !== value)) return false;
    for (const name of new Set(entries.map(([name2]) => name2))) formData.delete(name);
    for (const [name, value] of entries) formData.append(name, typeof value === "string" ? stripMarks(value) : value);
    return true;
  }

  // js/in_context/slots.js
  var records = /* @__PURE__ */ new WeakMap();
  function textSlot(node, kind = "text") {
    return {
      type: "text",
      kind,
      node,
      read: () => node.nodeValue ?? "",
      write: (value) => {
        node.nodeValue = value;
      },
      element: () => node.parentElement,
      isConnected: () => node.isConnected
    };
  }
  function attributeSlot(el, attr, kind = "attribute") {
    return {
      type: "attribute",
      kind,
      el,
      attr,
      read: () => el.getAttribute(attr) ?? "",
      write: (value) => el.setAttribute(attr, value),
      element: () => el,
      isConnected: () => el.isConnected
    };
  }
  function baseValue(slot) {
    const current = slot.read();
    const record = records.get(slot);
    return record && record.written === current ? record.base : current;
  }
  function isOwnWrite(slot) {
    const record = records.get(slot);
    return Boolean(record) && record.written === slot.read();
  }
  function setSlotValue(slot, base, value) {
    const current = slot.read();
    if (value === base) {
      if (current !== base) slot.write(base);
      records.delete(slot);
      return;
    }
    if (current !== value) slot.write(value);
    records.set(slot, { base, written: value });
  }

  // js/in_context/scanner.js
  var SKIP_PARENTS = /* @__PURE__ */ new Set(["script", "style", "noscript", "template", "textarea"]);
  var ALWAYS_ATTRS = ["placeholder", "title", "alt", "aria-label", "aria-description"];
  var OBSERVED_ATTRS = [...ALWAYS_ATTRS, "value", "content"];
  var ATTR_SELECTOR = [
    ...ALWAYS_ATTRS.map((attr) => `[${attr}]`),
    "button[value]",
    'input[type="button"][value]',
    'input[type="submit"][value]',
    "meta[content]"
  ].join(",");
  var META_NAME = /^(description|og:|twitter:)/;
  var CONTROL_SELECTOR = "input, textarea";
  var visibilityOptions = { checkOpacity: true, checkVisibilityCSS: true };
  function relevantAttributes(el) {
    const attrs = ALWAYS_ATTRS.filter((attr) => el.hasAttribute(attr));
    const tag = el.localName;
    if (tag === "input" && el.hasAttribute("value") && /^(button|submit)$/i.test(el.getAttribute("type") ?? "")) {
      attrs.unshift("value");
    }
    if (tag === "button" && el.hasAttribute("value")) attrs.push("value");
    if (tag === "meta" && el.hasAttribute("content")) {
      const name = (el.getAttribute("name") ?? el.getAttribute("property") ?? "").toLowerCase();
      if (META_NAME.test(name)) attrs.push("content");
    }
    return attrs;
  }
  function textKind(node) {
    const parent = node.parentElement;
    return parent && parent.localName === "title" && parent.closest("head") ? "title" : "text";
  }
  function attributeKind(el, attr) {
    return el.localName === "meta" && attr === "content" ? "meta" : "attribute";
  }
  function visible(el) {
    if (!el) return false;
    return typeof el.checkVisibility === "function" ? el.checkVisibility(visibilityOptions) : true;
  }
  function intersects(rect, viewport) {
    return rect.width + rect.height > 0 && rect.bottom > viewport.top && rect.top < viewport.bottom && rect.right > viewport.left && rect.left < viewport.right;
  }
  function createScanner({ isIgnored = () => false, viewport, onChange = () => {
  } }) {
    const slots = /* @__PURE__ */ new Set();
    const textSlots = /* @__PURE__ */ new Map();
    const attributeSlots = /* @__PURE__ */ new Map();
    const controls = /* @__PURE__ */ new Map();
    let controlsChanged = false;
    let observer = null;
    let pending = null;
    let frame = 0;
    const skipText = (node) => {
      const parent = node.parentElement;
      return !parent || SKIP_PARENTS.has(parent.localName) || isIgnored(parent);
    };
    function scanControl(el) {
      if (isIgnored(el) || !isDataControl(el)) return false;
      const value = el.value;
      if (typeof value !== "string" || !hasMarks(value)) return false;
      const slot = { type: "control", kind: "attribute", el, element: () => el, isConnected: () => el.isConnected };
      slot.occurrences = markedStrings(value).map((found) => ({ ...found, kind: "attribute", slot, onScreen: false }));
      controls.set(el, slot);
      controlsChanged = true;
      el.value = stripMarks(value);
      return true;
    }
    function build(slot) {
      const value = slot.read();
      if (!hasMarks(value)) return false;
      const live = flattenSegments(parseSegments(value));
      const base = baseValue(slot);
      const baseFlat = base === value ? live : flattenSegments(parseSegments(base));
      slot.occurrences = live.map((segment, index) => {
        const source = baseFlat.length === live.length ? baseFlat[index] : segment;
        const from = baseFlat.length === live.length ? base : value;
        return {
          domain: segment.domain,
          key: segment.key,
          locale: segment.locale,
          kind: slot.kind,
          slot,
          segment,
          text: segmentText(from, source),
          onScreen: false
        };
      });
      return true;
    }
    function drop(slot) {
      slots.delete(slot);
      if (slot.type === "text") {
        textSlots.delete(slot.node);
      } else {
        const map = attributeSlots.get(slot.el);
        if (map) {
          map.delete(slot.attr);
          if (!map.size) attributeSlots.delete(slot.el);
        }
      }
    }
    function textSlotFor(node) {
      let slot = textSlots.get(node);
      if (!slot) {
        slot = textSlot(node, textKind(node));
        textSlots.set(node, slot);
      }
      return slot;
    }
    function attributeSlotFor(el, attr) {
      let map = attributeSlots.get(el);
      if (!map) attributeSlots.set(el, map = /* @__PURE__ */ new Map());
      let slot = map.get(attr);
      if (!slot) {
        slot = attributeSlot(el, attr, attributeKind(el, attr));
        map.set(attr, slot);
      }
      return slot;
    }
    function refresh(slot) {
      if (!slot.isConnected() || !build(slot)) {
        if (slots.has(slot)) drop(slot);
        return false;
      }
      slots.add(slot);
      return true;
    }
    function scanText(node, changed) {
      if (node.parentElement?.localName === "textarea") {
        scanControl(node.parentElement);
        return;
      }
      if (skipText(node)) return;
      const known = textSlots.get(node);
      if (!hasMarks(node.nodeValue ?? "")) {
        if (known && slots.has(known)) {
          drop(known);
          changed.add(known);
        }
        return;
      }
      const slot = textSlotFor(node);
      if (refresh(slot)) changed.add(slot);
    }
    function scanElementAttributes(el, changed) {
      if (isIgnored(el)) return;
      scanControl(el);
      const wanted = new Set(relevantAttributes(el));
      for (const attr of wanted) {
        const value = el.getAttribute(attr) ?? "";
        const known = attributeSlots.get(el)?.get(attr);
        if (!value.includes(OPEN)) {
          if (known && slots.has(known)) {
            drop(known);
            changed.add(known);
          }
          continue;
        }
        const slot = attributeSlotFor(el, attr);
        if (refresh(slot)) changed.add(slot);
      }
    }
    function scanTree(root, changed) {
      if (root.nodeType === Node.TEXT_NODE) {
        scanText(root, changed);
        return;
      }
      if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return;
      if (root.nodeType === Node.ELEMENT_NODE && isIgnored(root)) return;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) scanText(node, changed);
      if (root.nodeType === Node.ELEMENT_NODE && root.matches(ATTR_SELECTOR)) scanElementAttributes(root, changed);
      for (const el of root.querySelectorAll(ATTR_SELECTOR)) scanElementAttributes(el, changed);
      if (root.nodeType === Node.ELEMENT_NODE && root.matches(CONTROL_SELECTOR)) scanControl(root);
      for (const el of root.querySelectorAll(CONTROL_SELECTOR)) scanControl(el);
    }
    function prune(changed) {
      for (const slot of [...slots]) {
        if (!slot.isConnected()) {
          drop(slot);
          changed.add(slot);
        }
      }
      for (const el of [...controls.keys()]) {
        if (!el.isConnected) {
          controls.delete(el);
          controlsChanged = true;
        }
      }
    }
    function queue() {
      if (!frame) frame = requestAnimationFrame(flush);
    }
    function flush() {
      frame = 0;
      const work2 = pending;
      pending = null;
      if (!work2) return;
      const changed = /* @__PURE__ */ new Set();
      controlsChanged = false;
      if (work2.removed) prune(changed);
      for (const root of work2.trees) if (root.isConnected) scanTree(root, changed);
      for (const node of work2.text) if (node.isConnected) scanText(node, changed);
      for (const el of work2.attributes) if (el.isConnected) scanElementAttributes(el, changed);
      if (changed.size || controlsChanged) onChange([...changed]);
    }
    function work() {
      return pending ?? (pending = { trees: /* @__PURE__ */ new Set(), text: /* @__PURE__ */ new Set(), attributes: /* @__PURE__ */ new Set(), removed: false });
    }
    function onMutations(records2) {
      for (const record of records2) {
        if (record.type === "childList") {
          if (record.removedNodes.length) work().removed = true;
          for (const node of record.addedNodes) if (!isIgnored(node)) work().trees.add(node);
        } else if (record.type === "characterData") {
          const known = textSlots.get(record.target);
          if (!(known && isOwnWrite(known))) work().text.add(record.target);
        } else if (record.type === "attributes") {
          const known = attributeSlots.get(record.target)?.get(record.attributeName);
          if (!(known && isOwnWrite(known))) work().attributes.add(record.target);
        }
      }
      if (pending) queue();
    }
    function occurrences() {
      const out = [];
      for (const slot of slots) out.push(...slot.occurrences);
      for (const slot of controls.values()) out.push(...slot.occurrences);
      return out;
    }
    function rangeFor(occurrence) {
      const { slot, segment } = occurrence;
      const range = document.createRange();
      try {
        range.setStart(slot.node, segment.start);
        range.setEnd(slot.node, segment.end);
      } catch {
        return null;
      }
      return range;
    }
    function rects(occurrence) {
      const { slot } = occurrence;
      const el = slot.element();
      if (!el || !visible(el)) return [];
      if (slot.type === "text") {
        const range = rangeFor(occurrence);
        return range ? [...range.getClientRects()].filter((r) => r.width + r.height > 0) : [];
      }
      const box = el.getBoundingClientRect();
      return box.width + box.height > 0 ? [box] : [];
    }
    function measure() {
      const bounds = viewport();
      let changed = false;
      for (const occurrence of occurrences()) {
        const onScreen = occurrence.kind === "title" || occurrence.kind === "meta" ? false : rects(occurrence).some((rect) => intersects(rect, bounds));
        if (onScreen !== occurrence.onScreen) {
          occurrence.onScreen = onScreen;
          changed = true;
        }
      }
      return changed;
    }
    function start() {
      const changed = /* @__PURE__ */ new Set();
      scanTree(document, changed);
      observer = new MutationObserver(onMutations);
      observer.observe(document.documentElement, {
        childList: true,
        characterData: true,
        subtree: true,
        attributes: true,
        attributeFilter: OBSERVED_ATTRS
      });
      return [...changed];
    }
    function stop() {
      observer?.disconnect();
      observer = null;
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      pending = null;
    }
    const textSlotOf = (node) => {
      const slot = textSlots.get(node);
      return slot && slots.has(slot) ? slot : null;
    };
    const attributeSlotsOf = (el) => [
      ...controls.has(el) ? [controls.get(el)] : [],
      ...[...attributeSlots.get(el)?.values() ?? []].filter((slot) => slots.has(slot))
    ];
    return { start, stop, refresh, slots: () => slots, occurrences, rects, measure, textSlotOf, attributeSlotsOf };
  }

  // js/in_context/canvas.js
  var MARKER = "__dialectoInContext";
  var visibilityOptions2 = { checkOpacity: true, checkVisibilityCSS: true };
  function installCanvas({ transform: transform2, onResults = () => {
  }, onSeen = () => {
  } }) {
    const proto = typeof CanvasRenderingContext2D === "undefined" ? null : CanvasRenderingContext2D.prototype;
    if (!proto || proto.fillText[MARKER]) return { installed: false, occurrences: () => [], rects: () => [], measure: () => false };
    const original = {
      fillText: proto.fillText,
      strokeText: proto.strokeText,
      measureText: proto.measureText,
      clearRect: proto.clearRect
    };
    const canvases = /* @__PURE__ */ new Map();
    const stateFor = (canvas) => {
      let state = canvases.get(canvas);
      if (!state) canvases.set(canvas, state = { generation: 0, seen: /* @__PURE__ */ new Map() });
      return state;
    };
    function boxOf(ctx, text3, x, y) {
      const metrics = original.measureText.call(ctx, text3);
      const m = ctx.getTransform();
      const xs = [x - metrics.actualBoundingBoxLeft, x + metrics.actualBoundingBoxRight];
      const ys = [y - metrics.actualBoundingBoxAscent, y + metrics.actualBoundingBoxDescent];
      const corners = xs.flatMap((cx) => ys.map((cy) => [m.a * cx + m.c * cy + m.e, m.b * cx + m.d * cy + m.f]));
      const px = corners.map((c) => c[0]);
      const py = corners.map((c) => c[1]);
      return { left: Math.min(...px), top: Math.min(...py), right: Math.max(...px), bottom: Math.max(...py) };
    }
    function record(ctx, source, drawn, x, y) {
      const canvas = ctx.canvas;
      if (!(canvas instanceof HTMLCanvasElement)) return;
      const state = stateFor(canvas);
      let box = null;
      try {
        box = boxOf(ctx, drawn, Number(x) || 0, Number(y) || 0);
      } catch {
        box = null;
      }
      for (const segment of flattenSegments(parseSegments(source))) {
        const id = keyId(segment.domain, segment.key, segment.locale);
        const known = state.seen.get(id);
        const revived = !known || known.generation < state.generation - 1;
        state.seen.set(id, {
          domain: segment.domain,
          key: segment.key,
          locale: segment.locale,
          kind: "canvas",
          text: segmentText(source, segment),
          canvas,
          box,
          generation: state.generation,
          onScreen: known?.onScreen ?? false
        });
        if (revived) onSeen();
      }
    }
    function wrapDraw(name) {
      const draw = original[name];
      const wrapped = function(text3, x, y, ...rest) {
        if (typeof text3 !== "string" || text3.indexOf(OPEN) < 0) return draw.call(this, text3, x, y, ...rest);
        let drawn = text3;
        try {
          const { value, results } = transform2(text3);
          drawn = stripMarks(value);
          if (results.length) onResults(results);
          record(this, text3, drawn, x, y);
        } catch {
          drawn = stripMarks(text3);
        }
        return draw.call(this, drawn, x, y, ...rest);
      };
      wrapped[MARKER] = true;
      return wrapped;
    }
    proto.fillText = wrapDraw("fillText");
    proto.strokeText = wrapDraw("strokeText");
    proto.measureText = function(text3) {
      if (typeof text3 !== "string" || text3.indexOf(OPEN) < 0) return original.measureText.call(this, text3);
      try {
        return original.measureText.call(this, stripMarks(transform2(text3).value));
      } catch {
        return original.measureText.call(this, stripMarks(text3));
      }
    };
    proto.clearRect = function(x, y, w, h) {
      const canvas = this.canvas;
      if (canvases.has(canvas) && w >= canvas.width && h >= canvas.height) canvases.get(canvas).generation += 1;
      return original.clearRect.call(this, x, y, w, h);
    };
    function entries() {
      const out = [];
      for (const [canvas, state] of canvases) {
        if (!canvas.isConnected) {
          canvases.delete(canvas);
          continue;
        }
        for (const [id, entry] of state.seen) {
          if (entry.generation < state.generation - 1) state.seen.delete(id);
          else out.push(entry);
        }
      }
      return out;
    }
    function rects(entry) {
      const { canvas, box } = entry;
      const visible2 = canvas.checkVisibility ? canvas.checkVisibility(visibilityOptions2) : true;
      if (!canvas.isConnected || !visible2) return [];
      const frame = canvas.getBoundingClientRect();
      if (!(frame.width + frame.height > 0)) return [];
      if (!box || !canvas.width || !canvas.height) return [frame];
      const sx = frame.width / canvas.width;
      const sy = frame.height / canvas.height;
      return [
        {
          left: frame.left + box.left * sx,
          top: frame.top + box.top * sy,
          right: frame.left + box.right * sx,
          bottom: frame.top + box.bottom * sy,
          width: (box.right - box.left) * sx,
          height: (box.bottom - box.top) * sy
        }
      ];
    }
    function measure(viewport) {
      let changed = false;
      for (const entry of entries()) {
        const onScreen = rects(entry).some((rect) => intersects(rect, viewport));
        if (onScreen !== entry.onScreen) {
          entry.onScreen = onScreen;
          changed = true;
        }
      }
      return changed;
    }
    return { installed: true, occurrences: entries, rects, measure };
  }

  // js/in_context/click.js
  var CONTROL_TAGS = /* @__PURE__ */ new Set([
    "button",
    "input",
    "select",
    "textarea",
    "label",
    "summary",
    "option",
    "audio",
    "video",
    "canvas",
    "iframe",
    "embed",
    "object"
  ]);
  var CONTROL_ROLES = /* @__PURE__ */ new Set([
    "button",
    "link",
    "tab",
    "menuitem",
    "menuitemcheckbox",
    "menuitemradio",
    "option",
    "checkbox",
    "radio",
    "switch",
    "slider",
    "combobox",
    "treeitem"
  ]);
  var CLICK_ATTRS = ["onclick", "phx-click", "x-on:click", "@click", "v-on:click"];
  var SHOWN_ATTRS = /* @__PURE__ */ new Set(["placeholder", "value"]);
  function isControl(el) {
    const tag = el.localName;
    if (CONTROL_TAGS.has(tag)) return true;
    if (tag === "a" && el.hasAttribute("href")) return true;
    if (CONTROL_ROLES.has(el.getAttribute("role"))) return true;
    const editable = el.getAttribute("contenteditable");
    if (editable !== null && editable !== "false") return true;
    if (el.getAttribute("draggable") === "true") return true;
    return CLICK_ATTRS.some((attr) => el.hasAttribute(attr));
  }
  var computedCursor = (el) => getComputedStyle(el).cursor;
  function actsOnClick(el, cursorOf = computedCursor) {
    if (!el) return false;
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      if (isControl(node)) return true;
    }
    return cursorOf(el) === "pointer";
  }
  function shownOnPage(occurrence) {
    if (occurrence.kind === "canvas") return true;
    const slot = occurrence.slot;
    if (!slot) return false;
    if (slot.type === "text") return slot.kind === "text";
    if (slot.type === "control") return true;
    return SHOWN_ATTRS.has(slot.attr);
  }
  var elementOf = (occurrence) => occurrence.kind === "canvas" ? occurrence.canvas : occurrence.slot?.element() ?? null;

  // js/in_context/highlight.js
  var TAB_HEIGHT = 22;
  var TAB_DELAY = 220;
  var CSS = `
.layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483646; overflow: hidden; }
.box {
  position: absolute; left: 0; top: 0; display: none; box-sizing: border-box; border-radius: 6px;
  background: rgba(62, 154, 209, 0.14);
  box-shadow: 0 0 0 2px #2b7cad, 0 0 0 3.5px rgba(255, 255, 255, 0.85);
  opacity: 0; transition: opacity 140ms ease-out;
}
.box.on { opacity: 1; }
.box.hover { background: rgba(28, 92, 134, 0.1); box-shadow: 0 0 0 2px #1c5c86, 0 0 0 3.5px rgba(255, 255, 255, 0.85); }
.box.reveal {
  border-radius: 4px; background: rgba(62, 154, 209, 0.07);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.6); outline: 1.5px dashed rgba(28, 92, 134, 0.75); outline-offset: 0;
}
.box.pulse::after {
  content: ""; position: absolute; inset: -2px; border-radius: inherit; border: 2px solid #3e9ad1;
  animation: pulse 700ms ease-out 1 forwards;
}
@keyframes pulse { from { opacity: 0.9; transform: scale(1); } to { opacity: 0; transform: scale(1.06, 1.3); } }
.tab {
  position: absolute; left: 0; top: 0; display: none; align-items: center; gap: 4px;
  height: ${TAB_HEIGHT}px; margin: 0; padding: 0 8px 0 6px; border: 0; border-radius: 6px 6px 0 0;
  background: #1c5c86; color: #fff; box-shadow: 0 -1.5px 0 1.5px rgba(255, 255, 255, 0.85);
  font: 600 11.5px/1 system-ui, -apple-system, "Segoe UI", sans-serif; letter-spacing: 0.01em;
  pointer-events: auto; cursor: pointer; opacity: 0; transition: opacity 120ms ease-out, background-color 120ms;
}
.tab.below { border-radius: 0 0 6px 6px; box-shadow: 0 1.5px 0 1.5px rgba(255, 255, 255, 0.85); }
.tab.on { opacity: 1; }
.tab:hover { background: #164a6c; }
.tab svg { width: 12px; height: 12px; flex: none; }
@media (prefers-reduced-motion: reduce) {
  .box, .tab { transition: none; }
  .box.pulse::after { animation: none; display: none; }
}
`;
  var PENCIL = '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M13.6 3.4a1.9 1.9 0 0 1 2.7 0l.3.3a1.9 1.9 0 0 1 0 2.7L7.3 15.7 3 17l1.3-4.3 9.3-9.3Z" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/></svg>';
  var PAD_X = 3;
  var PAD_Y = 0;
  function createHighlighter({ root, scanner, canvas, getViewport, onTab = () => {
  } }) {
    const style = document.createElement("style");
    style.textContent = CSS;
    const layer = document.createElement("div");
    layer.className = "layer";
    layer.setAttribute("aria-hidden", "true");
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = "tab";
    tab.tabIndex = -1;
    tab.innerHTML = `${PENCIL}<span>Edit</span>`;
    layer.append(tab);
    root.append(style, layer);
    const pool = [];
    let target = null;
    let hover = null;
    let hoverTab = false;
    let tabReady = false;
    let tabTimer = 0;
    let reveal = false;
    let frame = 0;
    let pulseNext = false;
    tab.addEventListener("mousedown", (event) => event.preventDefault());
    tab.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      onTab();
    });
    const boxAt = (index) => {
      while (pool.length <= index) {
        const el = document.createElement("div");
        el.className = "box";
        layer.insertBefore(el, tab);
        pool.push(el);
      }
      return pool[index];
    };
    function separateLines(rects) {
      const lines = rects.map((r) => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom })).sort((a, b) => a.top - b.top);
      for (let i = 1; i < lines.length; i++) {
        const prev = lines[i - 1];
        const line = lines[i];
        if (line.top < prev.bottom && line.left < prev.right && line.right > prev.left) {
          const mid = (line.top + prev.bottom) / 2;
          prev.bottom = mid;
          line.top = mid;
        }
      }
      return lines.map((l) => ({ ...l, width: l.right - l.left, height: l.bottom - l.top }));
    }
    const rectsOf = (occurrence) => separateLines(occurrence.kind === "canvas" ? canvas.rects(occurrence) : scanner.rects(occurrence));
    const all = () => [...scanner.occurrences(), ...canvas.occurrences()];
    const matching = ({ domain, key }) => all().filter((occ) => occ.domain === domain && occ.key === key);
    const isTarget = (occ) => target !== null && occ.domain === target.domain && occ.key === target.key;
    function placeTab(rects, bounds) {
      const show = hover && hoverTab && tabReady && rects.length > 0;
      if (!show) {
        tab.style.display = "none";
        tab.classList.remove("on");
        return;
      }
      const first = rects[0];
      const lastLine = rects[rects.length - 1];
      const below = first.top - PAD_Y - TAB_HEIGHT < bounds.top;
      const fresh = tab.style.display !== "flex";
      tab.style.display = "flex";
      tab.classList.toggle("below", below);
      const width = tab.offsetWidth;
      const left = Math.min(Math.max(first.left - PAD_X - 2, bounds.left + 2), bounds.right - width - 2);
      const top = below ? lastLine.bottom + PAD_Y : first.top - PAD_Y - TAB_HEIGHT;
      tab.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
      if (fresh) requestAnimationFrame(() => tab.classList.add("on"));
    }
    function paint() {
      const bounds = getViewport();
      const drawn = [];
      if (reveal) {
        for (const occurrence of all()) {
          if (!occurrence.onScreen || occurrence === hover || isTarget(occurrence) || !shownOnPage(occurrence)) continue;
          for (const rect of rectsOf(occurrence)) if (intersects(rect, bounds)) drawn.push({ rect, kind: "reveal" });
        }
      }
      if (target) {
        for (const occurrence of matching(target)) {
          for (const rect of rectsOf(occurrence)) if (intersects(rect, bounds)) drawn.push({ rect, kind: "target" });
        }
      }
      const hoverRects = hover ? rectsOf(hover).filter((rect) => intersects(rect, bounds)) : [];
      for (const rect of hoverRects) drawn.push({ rect, kind: "hover" });
      drawn.forEach(({ rect, kind }, index) => {
        const el = boxAt(index);
        const fresh = el.style.display !== "block";
        el.style.display = "block";
        el.style.transform = `translate(${Math.round(rect.left - PAD_X)}px, ${Math.round(rect.top - PAD_Y)}px)`;
        el.style.width = `${Math.round(rect.width + PAD_X * 2)}px`;
        el.style.height = `${Math.round(rect.height + PAD_Y * 2)}px`;
        el.classList.toggle("hover", kind === "hover");
        el.classList.toggle("reveal", kind === "reveal");
        if (fresh) requestAnimationFrame(() => el.classList.add("on"));
        if (pulseNext && kind === "target") {
          el.classList.remove("pulse");
          void el.offsetWidth;
          el.classList.add("pulse");
        }
      });
      pulseNext = false;
      for (let i = drawn.length; i < pool.length; i++) {
        pool[i].style.display = "none";
        pool[i].classList.remove("on", "pulse");
      }
      placeTab(hoverRects, bounds);
    }
    const active = () => Boolean(target || hover || reveal);
    function tick() {
      frame = 0;
      paint();
      if (active()) frame = requestAnimationFrame(tick);
    }
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(tick);
    };
    function reducedMotion() {
      return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
    }
    const inView = (rect, bounds) => rect.top >= bounds.top && rect.bottom <= bounds.bottom && rect.left >= bounds.left && rect.right <= bounds.right;
    function scrollTo(occurrences) {
      const bounds = getViewport();
      if (occurrences.some((occ) => rectsOf(occ).some((rect) => inView(rect, bounds)))) return;
      const visible2 = occurrences.find((occ) => rectsOf(occ).length > 0) ?? occurrences[0];
      if (!visible2) return;
      const el = visible2.kind === "canvas" ? visible2.canvas : visible2.slot.element();
      el?.scrollIntoView({ block: "center", inline: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
    }
    return {
      /** Outline every occurrence of a message; `null` clears. */
      setTarget(next, { scroll = false } = {}) {
        const changed = !next !== !target || next && target && (next.domain !== target.domain || next.key !== target.key);
        target = next;
        if (next && changed) pulseNext = true;
        if (next && scroll) scrollTo(matching(next));
        if (!next) paint();
        schedule();
      },
      /** The string under the pointer; `tab` offers its Edit tab once the pointer rests. */
      setHover(occurrence, { tab: withTab = false } = {}) {
        if (occurrence === hover && withTab === hoverTab) return;
        if (!occurrence || !withTab) tabReady = false;
        if (tabTimer) clearTimeout(tabTimer);
        tabTimer = 0;
        hover = occurrence;
        hoverTab = withTab;
        if (hover && hoverTab && !tabReady) {
          tabTimer = setTimeout(() => {
            tabTimer = 0;
            tabReady = true;
            schedule();
          }, TAB_DELAY);
        }
        if (!active()) paint();
        schedule();
      },
      /** Faintly outline every editable string on screen. */
      setReveal(on) {
        if (on === reveal) return;
        reveal = on;
        if (!active()) paint();
        schedule();
      },
      /** True when the event happened on the Edit tab. */
      isTabEvent: (event) => event.composedPath?.().includes(tab) === true,
      schedule,
      isActive: active,
      destroy() {
        if (frame) cancelAnimationFrame(frame);
        if (tabTimer) clearTimeout(tabTimer);
        layer.remove();
        style.remove();
      }
    };
  }

  // js/in_context/marking.js
  var HEARTBEAT_MS = 3e4;
  var RELOAD_GUARD_MS = 3e4;
  var RELOADED_KEY = "dialecto-in-context:marking-reload";
  function sessionStore() {
    try {
      return globalThis.sessionStorage ?? null;
    } catch {
      return null;
    }
  }
  function readReload(storage) {
    try {
      const value = JSON.parse(storage.getItem(RELOADED_KEY));
      return value && typeof value.url === "string" && typeof value.at === "number" ? value : null;
    } catch {
      return null;
    }
  }
  function writeReload(storage, value) {
    try {
      storage.setItem(RELOADED_KEY, JSON.stringify(value));
      return true;
    } catch {
      return false;
    }
  }
  function createMarking(endpoint, {
    hasMarkers = () => true,
    reload = () => globalThis.location?.reload(),
    fetchImpl = globalThis.fetch?.bind(globalThis),
    storage = sessionStore(),
    now = () => Date.now(),
    url = () => `${globalThis.location?.pathname ?? ""}${globalThis.location?.search ?? ""}`,
    timers = globalThis
  } = {}) {
    if (!endpoint || !fetchImpl) return { enabled: false, setOpen: async () => {
    }, isOpen: () => false };
    let open = false;
    let heartbeat = 0;
    async function send(on) {
      try {
        const response = await fetchImpl(endpoint, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ on }),
          credentials: "same-origin",
          // Turning it off must arrive even when the page goes away right after.
          keepalive: !on
        });
        return Boolean(response?.ok);
      } catch {
        return false;
      }
    }
    function reloadOnce() {
      if (!storage) return false;
      const here = url();
      const last = readReload(storage);
      if (last && last.url === here && now() - last.at < RELOAD_GUARD_MS) return false;
      if (!writeReload(storage, { url: here, at: now() })) return false;
      reload();
      return true;
    }
    return {
      enabled: true,
      isOpen: () => open,
      /** The editor opened or closed; resolves once the dev server answered. */
      async setOpen(next) {
        if (next === open) return;
        open = next;
        timers.clearInterval(heartbeat);
        heartbeat = 0;
        if (!next) {
          await send(false);
          return;
        }
        heartbeat = timers.setInterval(() => send(true), HEARTBEAT_MS);
        if (await send(true) && open && !hasMarkers()) reloadOnce();
      }
    };
  }

  // js/in_context/overrides.js
  var DEBOUNCE_MS = 400;
  var keyOf = (edit) => [edit.domain, edit.locale, edit.key].join("");
  function overrideOf({ domain, key, locale, to, forms, msgid_plural: plural }) {
    return Array.isArray(forms) && typeof plural === "string" ? { domain, key, locale, forms } : { domain, key, locale, to };
  }
  function createOverrideSync(endpoint, { fetchImpl = globalThis.fetch?.bind(globalThis) } = {}) {
    if (!endpoint || !fetchImpl) return { enabled: false, push() {
    } };
    let timer = 0;
    let lastSent = null;
    let queued = null;
    async function send(payload) {
      try {
        await fetchImpl(endpoint, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: payload,
          credentials: "same-origin",
          keepalive: true
        });
        lastSent = payload;
      } catch {
        lastSent = null;
      }
    }
    return {
      enabled: true,
      /** Debounced full replacement of the override set. */
      push(edits) {
        const list = edits.map(overrideOf).sort((a, b) => keyOf(a).localeCompare(keyOf(b)));
        const payload = JSON.stringify({ edits: list });
        if (payload === lastSent && timer === 0) return;
        queued = payload;
        clearTimeout(timer);
        timer = setTimeout(() => {
          timer = 0;
          if (queued !== null && queued !== lastSent) send(queued);
        }, DEBOUNCE_MS);
      }
    };
  }

  // js/in_context/url.js
  var LOOPBACK = /* @__PURE__ */ new Set(["localhost", "127.0.0.1", "[::1]"]);
  var isLoopback = (hostname) => LOOPBACK.has(hostname);
  function sidebarUrl(base, { site, project, locale } = {}) {
    const prefix = base.pathname.replace(/\/+$/, "");
    const params = new URLSearchParams();
    if (site) params.set("site", site);
    if (project) params.set("project", project);
    if (locale) params.set("locale", locale);
    const query = params.toString();
    return `${base.origin}${prefix}/in-context${query ? `?${query}` : ""}`;
  }

  // js/in_context/panel.js
  var PANEL_WIDTH = 380;
  var NARROW_BREAKPOINT = 720;
  var STORAGE_KEY = "dialecto-in-context:open";
  var DOCKED_CSS = `
@media (min-width: ${NARROW_BREAKPOINT + 1}px) { html { margin-right: ${PANEL_WIDTH}px; } }
`;
  var CSS2 = `
:host { all: initial; }
* { box-sizing: border-box; }
.ui {
  --cream: #fbf4e9; --paper: #ffffff; --edge: #e4d4b8; --ink: #33291f; --ink2: #6a5e4b;
  --terra: #ba563e; --terra-dk: #ad4b35; --sky: #3e9ad1; --sea: #1c5c86; --danger: #b5402c; --danger-bg: #f7e2dc;
  --shadow: 0 8px 22px -6px rgba(28, 49, 63, 0.35), 0 2px 5px rgba(28, 49, 63, 0.18);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; color: var(--ink);
}
@media (prefers-color-scheme: dark) {
  .ui { --cream: #1b1610; --paper: #271f17; --edge: #463b28; --ink: #f3ecdb; --ink2: #cabb9f; --sea: #4f93c2;
        --danger: #e0795f; --danger-bg: #3a201a; }
}
button { font: inherit; cursor: pointer; }
:focus-visible { outline: 3px solid var(--sky); outline-offset: 2px; }

.dock {
  position: fixed; right: 16px; bottom: 16px; z-index: 2147483647;
  display: flex; flex-direction: column; align-items: flex-end; gap: 8px;
  animation: rise 260ms cubic-bezier(0.2, 0.8, 0.2, 1) both;
}
.dock[hidden] { display: none; }
.dock.left { right: auto; left: 16px; align-items: flex-start; }
.dock.top { bottom: auto; top: 16px; }
.dock-row { display: flex; gap: 8px; }
.launcher, .stop {
  display: inline-flex; align-items: center; gap: 8px; height: 40px; border-radius: 999px;
  font-weight: 600; letter-spacing: 0.005em; box-shadow: var(--shadow);
  transition: background-color 120ms, border-color 120ms, transform 120ms, box-shadow 120ms;
}
.launcher { padding: 0 16px 0 13px; border: 0; background: var(--terra); color: #fff; }
.launcher:hover { background: var(--terra-dk); transform: translateY(-1px); }
.stop { padding: 0 16px; border: 1px solid var(--edge); background: var(--paper); color: var(--ink); }
.stop:hover { border-color: var(--ink2); transform: translateY(-1px); }
.stop:disabled { cursor: progress; opacity: 0.7; transform: none; }
.launcher:active, .stop:active { transform: translateY(0); }
.stop[hidden] { display: none; }
.launcher svg { width: 16px; height: 16px; flex: none; }
.stop-error {
  max-width: 280px; padding: 8px 12px; border-radius: 10px; background: var(--danger-bg); color: var(--danger);
  font-size: 13px; box-shadow: var(--shadow);
}
.stop-error[hidden] { display: none; }
@keyframes rise { from { opacity: 0; transform: translateY(8px); } }

.panel {
  position: fixed; top: 0; right: 0; bottom: 0; z-index: 2147483647; display: flex; flex-direction: column;
  width: min(${PANEL_WIDTH}px, 100vw); background: var(--cream); border-left: 1px solid var(--edge);
  box-shadow: -14px 0 32px -18px rgba(28, 49, 63, 0.4);
  transform: translateX(105%); visibility: hidden;
  transition: transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1), visibility 0s linear 220ms;
}
.panel.open { transform: translateX(0); visibility: visible; transition-delay: 0s; }
iframe { flex: 1; width: 100%; min-height: 0; border: 0; background: var(--cream); color-scheme: normal; }

.state {
  position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center;
  gap: 10px; padding: 32px 28px; text-align: center; background: var(--cream);
}
.state[hidden] { display: none; }
.spinner {
  width: 22px; height: 22px; border-radius: 50%; border: 2.5px solid var(--edge); border-top-color: var(--sea);
  animation: spin 800ms linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
.muted { color: var(--ink2); }
.badge {
  display: grid; place-items: center; width: 44px; height: 44px; border-radius: 50%;
  background: var(--danger-bg); color: var(--danger);
}
.badge svg { width: 22px; height: 22px; }
h2 { margin: 4px 0 0; font-size: 17px; line-height: 1.3; font-weight: 650; }
p { margin: 0; max-width: 32ch; }
.hint { max-width: 36ch; font-size: 13px; color: var(--ink2); }
code { font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; padding: 1px 5px; border-radius: 4px;
       background: var(--paper); border: 1px solid var(--edge); overflow-wrap: anywhere; }
.actions { display: flex; gap: 8px; margin-top: 8px; }
.btn { height: 36px; padding: 0 14px; border-radius: 8px; border: 1px solid var(--edge); background: var(--paper);
       color: var(--ink); font-weight: 600; }
.btn:hover { border-color: var(--ink2); }
.btn.primary { background: var(--terra); border-color: var(--terra); color: #fff; }
.btn.primary:hover { background: var(--terra-dk); border-color: var(--terra-dk); }

@media (prefers-reduced-motion: reduce) {
  .dock, .launcher, .stop, .panel { transition: none; animation: none; }
  .spinner { animation-duration: 2.4s; }
}
`;
  var PENCIL2 = '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M13.6 3.4a1.9 1.9 0 0 1 2.7 0l.3.3a1.9 1.9 0 0 1 0 2.7L7.3 15.7 3 17l1.3-4.3 9.3-9.3Z" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/><path d="m12 5 3 3" stroke="currentColor" stroke-width="1.7"/></svg>';
  var ALERT = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 8v5m0 3.5h.01M10.3 3.9 2.6 17.2A2 2 0 0 0 4.3 20h15.4a2 2 0 0 0 1.7-2.8L13.7 3.9a2 2 0 0 0-3.4 0Z" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  function readOpen() {
    try {
      return sessionStorage.getItem(STORAGE_KEY) === "1";
    } catch {
      return false;
    }
  }
  function writeOpen(open) {
    try {
      sessionStorage.setItem(STORAGE_KEY, open ? "1" : "0");
    } catch {
    }
  }
  function createPanel({
    corner = "bottom-right",
    root,
    src,
    dialectoUrl,
    siteOrigin,
    onOpenChange = () => {
    },
    onFrameLoad = () => {
    },
    onRetry = () => {
    },
    onStop = null
  }) {
    const hostStyle = document.createElement("style");
    document.head.append(hostStyle);
    const style = document.createElement("style");
    style.textContent = CSS2;
    const ui = document.createElement("div");
    ui.className = "ui";
    ui.innerHTML = `
    <div class="dock">
      <p class="stop-error" role="alert" hidden>Couldn\u2019t stop editing. Try again.</p>
      <div class="dock-row">
        <button class="stop" type="button" hidden>Stop editing</button>
        <button class="launcher" type="button">${PENCIL2}<span>Edit text</span></button>
      </div>
    </div>
    <aside class="panel" role="complementary" aria-label="Dialecto editor" inert>
      <div class="state connecting" role="status">
        <div class="spinner"></div>
        <p class="muted">Connecting to Dialecto\u2026</p>
      </div>
      <div class="state failed" role="alert" hidden>
        <div class="badge">${ALERT}</div>
        <h2>Can\u2019t reach Dialecto</h2>
        <p class="muted">The editor didn\u2019t answer from <code class="url"></code></p>
        <p class="hint"></p>
        <div class="actions">
          <button class="btn primary retry" type="button">Try again</button>
          <button class="btn close" type="button">Close</button>
        </div>
      </div>
    </aside>`;
    root.append(style, ui);
    const dock = ui.querySelector(".dock");
    dock.classList.toggle("left", corner.endsWith("left"));
    dock.classList.toggle("top", corner.startsWith("top"));
    const launcher = ui.querySelector(".launcher");
    const stop = ui.querySelector(".stop");
    const stopError = ui.querySelector(".stop-error");
    const panel = ui.querySelector(".panel");
    const connecting = ui.querySelector(".connecting");
    const failed = ui.querySelector(".failed");
    ui.querySelector(".url").textContent = dialectoUrl;
    const code = (value) => Object.assign(document.createElement("code"), { textContent: value });
    ui.querySelector(".hint").append(
      ...isLoopback(location.hostname) ? ["Check that Dialecto is running at ", code(dialectoUrl), "."] : ["Check that Dialecto is running, and that ", code(siteOrigin), " is one of the project\u2019s sites."]
    );
    let iframe = null;
    let open = false;
    function ensureFrame() {
      if (iframe) return;
      iframe = document.createElement("iframe");
      iframe.title = "Dialecto in-context editor";
      iframe.allow = "clipboard-write";
      iframe.referrerPolicy = "origin";
      iframe.addEventListener("load", () => onFrameLoad());
      iframe.src = src;
      panel.insertBefore(iframe, connecting);
    }
    function setOpen(next, { restored = false } = {}) {
      if (next === open) return;
      open = next;
      if (next) ensureFrame();
      panel.classList.toggle("open", next);
      panel.toggleAttribute("inert", !next);
      dock.hidden = next;
      hostStyle.textContent = next ? DOCKED_CSS : "";
      if (!restored) {
        writeOpen(next);
        (next ? iframe : launcher)?.focus({ preventScroll: true });
      }
      onOpenChange(next);
    }
    function showConnecting() {
      connecting.hidden = false;
      failed.hidden = true;
    }
    launcher.addEventListener("click", () => setOpen(true));
    if (typeof onStop === "function") {
      stop.hidden = false;
      stop.addEventListener("click", async () => {
        stop.disabled = true;
        stopError.hidden = true;
        stop.textContent = "Stopping\u2026";
        if (await onStop()) return;
        stop.disabled = false;
        stop.textContent = "Stop editing";
        stopError.hidden = false;
        stop.focus({ preventScroll: true });
      });
    }
    ui.querySelector(".close").addEventListener("click", () => setOpen(false));
    ui.querySelector(".retry").addEventListener("click", () => {
      showConnecting();
      onRetry();
      if (iframe) iframe.src = src;
    });
    if (readOpen()) setOpen(true, { restored: true });
    return {
      open: () => setOpen(true),
      close: () => setOpen(false),
      isOpen: () => open,
      frameWindow: () => iframe?.contentWindow ?? null,
      showConnecting,
      /** Names the shortcut in the launcher's tooltip, once. */
      setShortcut(label) {
        launcher.title = label ? `Edit text (${label} shows or hides Dialecto)` : "Edit text";
      },
      showReady() {
        connecting.hidden = true;
        failed.hidden = true;
      },
      showError() {
        connecting.hidden = true;
        failed.hidden = false;
        if (open) failed.querySelector(".retry").focus({ preventScroll: true });
      },
      /** Right edge of the page area not covered by the sidebar. */
      usableRight: () => open && window.innerWidth > NARROW_BREAKPOINT ? window.innerWidth - PANEL_WIDTH : window.innerWidth,
      destroy() {
        hostStyle.remove();
        style.remove();
        ui.remove();
      }
    };
  }

  // js/in_context/picker.js
  var PICK_CLASS = "dialecto-in-context-picking";
  var OPENS_ATTR = "data-dialecto-opens";
  var SLOP = 2;
  var DRAG = 4;
  var REVEAL_DELAY = 180;
  var CSS3 = `
html.${PICK_CLASS}, html.${PICK_CLASS} * { cursor: crosshair !important; }
[${OPENS_ATTR}], [${OPENS_ATTR}] * { cursor: pointer !important; }
`;
  function caretFromPoint(x, y) {
    if (document.caretPositionFromPoint) {
      const position = document.caretPositionFromPoint(x, y);
      return position ? { node: position.offsetNode, offset: position.offset } : null;
    }
    if (document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(x, y);
      return range ? { node: range.startContainer, offset: range.startOffset } : null;
    }
    return null;
  }
  var contains = (rect, x, y) => x >= rect.left - SLOP && x <= rect.right + SLOP && y >= rect.top - SLOP && y <= rect.bottom + SLOP;
  var plainClick = (event) => event.button === 0 && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey && event.detail <= 1;
  function createPicker({ scanner, canvas, highlighter, onPick, isInside, isEditing = () => false }) {
    let pickMode = false;
    let paused = false;
    let altReveal = false;
    let revealTimer = 0;
    let last = { x: -1, y: -1, target: null, altKey: false };
    let press = null;
    let hoverFrame = 0;
    let hover = null;
    let hoverOpens = false;
    let marked = null;
    const style = document.createElement("style");
    style.textContent = CSS3;
    document.head.append(style);
    function textOccurrenceAt(x, y) {
      const caret = caretFromPoint(x, y);
      if (!caret || caret.node?.nodeType !== Node.TEXT_NODE) return null;
      const slot = scanner.textSlotOf(caret.node);
      if (!slot) return null;
      const candidates = slot.occurrences.filter(({ segment }) => segment.start <= caret.offset && caret.offset <= segment.end).sort((a, b) => a.segment.end - a.segment.start - (b.segment.end - b.segment.start));
      return candidates.find((occ) => scanner.rects(occ).some((rect) => contains(rect, x, y))) ?? null;
    }
    function attributeOccurrenceAt(x, y, target, hidden) {
      for (let el = target; el && el.nodeType === Node.ELEMENT_NODE; el = el.parentElement) {
        for (const slot of scanner.attributeSlotsOf(el)) {
          const occ = slot.occurrences?.[0];
          if (!occ || !hidden && !shownOnPage(occ)) continue;
          if (scanner.rects(occ).some((rect) => contains(rect, x, y))) return occ;
        }
      }
      return null;
    }
    function canvasOccurrenceAt(x, y) {
      let best = null;
      let bestArea = Infinity;
      for (const entry of canvas.occurrences()) {
        for (const rect of canvas.rects(entry)) {
          const area = rect.width * rect.height;
          if (contains(rect, x, y) && area < bestArea) {
            best = entry;
            bestArea = area;
          }
        }
      }
      return best;
    }
    function textOccurrenceUnder(x, y) {
      let best = null;
      let bestArea = Infinity;
      for (const occ of scanner.occurrences()) {
        if (occ.slot?.type !== "text") continue;
        for (const rect of scanner.rects(occ)) {
          const area = rect.width * rect.height;
          if (area < bestArea && contains(rect, x, y)) {
            best = occ;
            bestArea = area;
          }
        }
      }
      return best;
    }
    function occurrenceAt(x, y, target, { hidden }) {
      if (target && isInside(target)) return null;
      const drawn = target instanceof HTMLCanvasElement ? canvasOccurrenceAt(x, y) : null;
      return textOccurrenceAt(x, y) ?? drawn ?? textOccurrenceUnder(x, y) ?? attributeOccurrenceAt(x, y, target, hidden);
    }
    const pickingAll = () => pickMode || altReveal || last.altKey;
    function mark(el) {
      if (marked === el) return;
      marked?.removeAttribute(OPENS_ATTR);
      marked = el;
      el?.setAttribute(OPENS_ATTR, "");
    }
    function clickOpens(occ) {
      mark(null);
      const el = elementOf(occ);
      return shownOnPage(occ) && !actsOnClick(el);
    }
    function setHover(occ) {
      if (occ === hover) return;
      hover = occ;
      hoverOpens = Boolean(occ) && !pickingAll() && clickOpens(occ);
      mark(hoverOpens ? elementOf(occ) : null);
      highlighter.setHover(occ, { tab: Boolean(occ) && !pickingAll() });
    }
    function updateHover() {
      hoverFrame = 0;
      const { x, y, target } = last;
      const all = pickingAll();
      setHover(target && (all || isEditing()) ? occurrenceAt(x, y, target, { hidden: all }) : null);
    }
    function scheduleHover() {
      if (!hoverFrame) hoverFrame = requestAnimationFrame(updateHover);
    }
    function clearHover() {
      if (hoverFrame) cancelAnimationFrame(hoverFrame);
      hoverFrame = 0;
      setHover(null);
    }
    function refresh() {
      highlighter.setReveal(pickMode || altReveal);
      const current = hover;
      clearHover();
      if (current || last.target) scheduleHover();
    }
    function setAltReveal(on) {
      if (revealTimer) clearTimeout(revealTimer);
      revealTimer = 0;
      if (on === altReveal) return;
      altReveal = on;
      refresh();
    }
    function setPickMode(on) {
      if (on === pickMode) return;
      pickMode = on;
      document.documentElement.classList.toggle(PICK_CLASS, on);
      refresh();
    }
    function pick2(occ) {
      onPick({ domain: occ.domain, key: occ.key });
      setPickMode(false);
    }
    function swallow(event) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
    }
    const dragged = (event) => press !== null && Math.hypot(event.clientX - press.x, event.clientY - press.y) > DRAG;
    const listeners = [
      [
        "mousemove",
        (event) => {
          if (highlighter.isTabEvent(event)) return;
          const wasAlt = last.altKey;
          last = { x: event.clientX, y: event.clientY, target: event.target, altKey: event.altKey };
          if (event.altKey && !event.ctrlKey && !event.metaKey) setAltReveal(true);
          else if (wasAlt || altReveal || revealTimer) setAltReveal(false);
          scheduleHover();
        }
      ],
      [
        "keydown",
        (event) => {
          if (event.key === "Alt") {
            if (!event.ctrlKey && !event.metaKey && !event.shiftKey && !altReveal && !revealTimer) {
              revealTimer = setTimeout(() => setAltReveal(true), REVEAL_DELAY);
            }
            return;
          }
          if (altReveal || revealTimer) setAltReveal(false);
          if (event.key === "Escape" && pickMode) {
            setPickMode(false);
            event.stopPropagation();
          }
        }
      ],
      [
        "keyup",
        (event) => {
          if (event.key !== "Alt") return;
          last = { ...last, altKey: false };
          const revealed = altReveal;
          setAltReveal(false);
          if (!revealed) refresh();
        }
      ],
      [
        "blur",
        () => {
          last = { ...last, altKey: false };
          setAltReveal(false);
          if (!pickMode) clearHover();
        }
      ],
      [
        "pointerdown",
        (event) => {
          press = { x: event.clientX, y: event.clientY };
        }
      ],
      [
        "click",
        (event) => {
          if (event.target && isInside(event.target)) return;
          if (pickMode || event.altKey) {
            swallow(event);
            const occ2 = occurrenceAt(event.clientX, event.clientY, event.target, { hidden: true });
            if (occ2) pick2(occ2);
            return;
          }
          if (!isEditing() || !plainClick(event) || dragged(event)) return;
          const occ = occurrenceAt(event.clientX, event.clientY, event.target, { hidden: false });
          if (!occ || !(occ === hover ? hoverOpens : clickOpens(occ))) return;
          swallow(event);
          pick2(occ);
        }
      ]
    ];
    const pressEvents = ["pointerdown", "mousedown", "pointerup", "mouseup"].map((name) => [
      name,
      (event) => {
        if (!pickMode || event.target && isInside(event.target)) return;
        event.stopPropagation();
        if (name === "mousedown") event.preventDefault();
      }
    ]);
    const bound = [...listeners, ...pressEvents].map(([name, handler]) => [
      name,
      (event) => {
        if (!paused) handler(event);
      }
    ]);
    for (const [name, handler] of bound) {
      window.addEventListener(name, handler, { capture: true, passive: name === "mousemove" });
    }
    return {
      setPickMode,
      isPickMode: () => pickMode,
      setPaused(on) {
        if (on === paused) return;
        paused = on;
        if (!on) return;
        setPickMode(false);
        last = { ...last, altKey: false };
        setAltReveal(false);
        clearHover();
        mark(null);
      },
      /** The editor opened or closed. */
      refresh,
      /** Opens the string under the pointer (its Edit tab was clicked). */
      pickHover() {
        if (hover) pick2(hover);
      },
      destroy() {
        setPickMode(false);
        setAltReveal(false);
        clearHover();
        mark(null);
        style.remove();
        for (const [name, handler] of bound) {
          window.removeEventListener(name, handler, { capture: true });
        }
      }
    };
  }

  // js/in_context/args.js
  function pageFormatter() {
    const format = typeof window === "undefined" ? void 0 : window.__dialectoFormat;
    return typeof format === "function" ? format : null;
  }
  function reviveArgs(args, raw) {
    const children = parseSegments(raw);
    const values = {};
    for (const [name, value] of Object.entries(args)) {
      if (value !== null && typeof value === "object" && "$date" in value) {
        values[name] = new Date(value.$date);
      } else if (value !== null && typeof value === "object" && "$marked" in value) {
        const child = children.find((segment) => stripMarks(raw.slice(segment.start, segment.end)) === value.$marked);
        values[name] = child ? raw.slice(child.start, child.end) : value.$marked;
      } else {
        values[name] = value;
      }
    }
    return values;
  }
  function renderWithArgs(to, segment, raw, format) {
    if (!segment.args || typeof format !== "function") return null;
    try {
      const text3 = String(format(to, segment.locale, reviveArgs(segment.args, raw), raw));
      return { ok: true, text: text3, noop: text3 === raw };
    } catch (error) {
      return { ok: false, reason: error?.dialectoReason === "unsupported" ? "unsupported" : "invalid" };
    }
  }

  // js/in_context/plural_pick.js
  function pickPluralTemplate(forms, msgid, msgidPlural, n, form, rule = "elixir") {
    const fallback = rule === "django" ? forms[0] === "" : forms.some((each) => each === "");
    if (fallback) return { ok: true, template: n === 1 ? msgid : msgidPlural };
    if (form < forms.length) return { ok: true, template: forms[form] };
    return { ok: false, reason: "invalid" };
  }

  // js/in_context/icu_simple.js
  var IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;
  var TAG = /<\/?[A-Za-z]/;
  function tokenize(src) {
    if (typeof src !== "string") return null;
    if (src.includes("#") || src.includes("''") || src.includes("'{") || src.includes("'}") || TAG.test(src)) return null;
    const tokens = [];
    let literal = "";
    for (let i = 0; i < src.length; i++) {
      const char = src[i];
      if (char === "{") {
        const close = src.indexOf("}", i + 1);
        if (close < 0) return null;
        const inner = src.slice(i + 1, close);
        if (inner.includes("{") || inner.includes(",")) return null;
        const name = inner.trim();
        if (!IDENT.test(name)) return null;
        if (literal) tokens.push({ lit: literal });
        literal = "";
        tokens.push({ arg: name });
        i = close;
      } else if (char === "}") {
        return null;
      } else {
        literal += char;
      }
    }
    if (literal) tokens.push({ lit: literal });
    return tokens;
  }
  var isSimple = (src) => tokenize(src) !== null;
  var escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  function matcher(tokens) {
    const groups = /* @__PURE__ */ new Map();
    let source = "^";
    for (const token of tokens) {
      if ("lit" in token) {
        source += escapeRegExp(token.lit);
      } else if (groups.has(token.arg)) {
        source += `\\${groups.get(token.arg)}`;
      } else {
        groups.set(token.arg, groups.size + 1);
        source += "([\\s\\S]*?)";
      }
    }
    return { regex: new RegExp(`${source}$`), groups };
  }
  var PLACEHOLDER_BASE = 57344;
  var PLACEHOLDER_LIMIT = 6400;
  function atomize(rawText) {
    const segments = parseSegments(rawText);
    if (segments.length === 0 || segments.length > PLACEHOLDER_LIMIT) return null;
    const first = String.fromCharCode(PLACEHOLDER_BASE);
    const last = String.fromCharCode(PLACEHOLDER_BASE + segments.length - 1);
    if ([...rawText].some((char) => char >= first && char <= last)) return null;
    let text3 = "";
    let cursor = 0;
    const parts = [];
    const indexOf = /* @__PURE__ */ new Map();
    for (const segment of segments) {
      const part = rawText.slice(segment.start, segment.end);
      if (!indexOf.has(part)) {
        indexOf.set(part, parts.length);
        parts.push(part);
      }
      text3 += rawText.slice(cursor, segment.start) + String.fromCharCode(PLACEHOLDER_BASE + indexOf.get(part));
      cursor = segment.end;
    }
    text3 += rawText.slice(cursor);
    const restore = (value) => [...value].map((char) => {
      const index = char.charCodeAt(0) - PLACEHOLDER_BASE;
      return index >= 0 && index < parts.length ? parts[index] : char;
    }).join("");
    return { text: text3, restore };
  }
  function captureArgs(from, rawText) {
    const tokens = tokenize(from);
    if (!tokens) return { ok: false, reason: "unsupported" };
    const { regex, groups } = matcher(tokens);
    const atoms = atomize(rawText);
    const match = regex.exec(atoms ? atoms.text : rawText);
    if (!match) return { ok: false, reason: "mismatch" };
    const args = {};
    for (const [name, index] of groups) args[name] = atoms ? atoms.restore(match[index]) : match[index];
    return { ok: true, args };
  }
  function render(to, args) {
    const tokens = tokenize(to);
    if (!tokens) return { ok: false, reason: "unsupported" };
    let text3 = "";
    for (const token of tokens) {
      if ("lit" in token) {
        text3 += token.lit;
      } else if (Object.hasOwn(args, token.arg)) {
        text3 += args[token.arg];
      } else {
        return { ok: false, reason: "unknown_argument" };
      }
    }
    return { ok: true, text: text3 };
  }
  function previewText(from, to, rawText) {
    if (!isSimple(from) || !isSimple(to)) return { ok: false, reason: "unsupported" };
    const captured = captureArgs(from, rawText);
    if (!captured.ok) {
      return captureArgs(to, rawText).ok ? { ok: true, text: rawText, noop: true } : captured;
    }
    const rendered = render(to, captured.args);
    if (!rendered.ok) return rendered;
    return { ok: true, text: rendered.text, noop: rendered.text === rawText };
  }

  // js/in_context/python_format.js
  var NAMED = /%\(([A-Za-z_]\w*)\)([-#0 +]*\d*(?:\.\d*)?[hlL]?)([diouxXeEfFgGcrsa])/y;
  var NAMED_LOOSE = /%\([^)]*\)[-#0 +]*(?:\d+|\*)?(?:\.(?:\d+|\*)?)?[hlL]?[diouxXeEfFgGcrsa]/y;
  var NAMED_ANYWHERE = /%\([A-Za-z_]\w*\)[-#0 +]*\d*(?:\.\d+)?[hlL]?[diouxXeEfFgGcrsa]/;
  var POSITIONAL = /%[-#0 +]*(?:\d+|\*)?(?:\.(?:\d+|\*)?)?[hlL]?[diouxXeEfFgGcrsa]/y;
  var PLAIN_SPEC = "";
  var INTEGER_CONVERSIONS = "di";
  var PLAIN_CONVERSIONS = "sdi";
  var STEP_LIMIT = 5e4;
  function tokenize2(src) {
    if (/[{}]/.test(src)) return { reason: "unsupported" };
    const tokens = [];
    let literal = "";
    for (let i = 0; i < src.length; i++) {
      if (src[i] !== "%") {
        literal += src[i];
        continue;
      }
      if (src[i + 1] === "%") {
        literal += "%";
        i += 1;
        continue;
      }
      NAMED.lastIndex = i;
      const named = NAMED.exec(src);
      if (named) {
        if (literal) tokens.push({ lit: literal });
        literal = "";
        tokens.push({ arg: named[1], spec: named[2], conv: named[3] });
        i += named[0].length - 1;
        continue;
      }
      NAMED_LOOSE.lastIndex = i;
      const loose = NAMED_LOOSE.test(src);
      POSITIONAL.lastIndex = i;
      return { reason: loose || POSITIONAL.test(src) ? "unsupported" : "invalid" };
    }
    if (literal) tokens.push({ lit: literal });
    return { tokens };
  }
  function usesPythonFormat(edit) {
    const { msgid } = splitKey(edit.key);
    const sources = [msgid, edit.msgid_plural, ...edit.from_forms ?? [edit.from]];
    const texts = sources.filter((each) => typeof each === "string");
    return texts.some((each) => NAMED_ANYWHERE.test(each)) && !texts.some((each) => each.includes("%{"));
  }
  function captures(tokens, text3) {
    const found = /* @__PURE__ */ new Map();
    let steps = 0;
    const walk = (index, pos, bound) => {
      if (found.size > 1 || steps++ > STEP_LIMIT) return;
      if (index === tokens.length) {
        if (pos === text3.length) found.set(JSON.stringify(bound), bound);
        return;
      }
      const token = tokens[index];
      if ("lit" in token) {
        if (text3.startsWith(token.lit, pos)) walk(index + 1, pos + token.lit.length, bound);
        return;
      }
      if (Object.hasOwn(bound, token.arg)) {
        const value = bound[token.arg].text;
        if (text3.startsWith(value, pos)) walk(index + 1, pos + value.length, bound);
        return;
      }
      const next = tokens[index + 1];
      const literalNext = next && "lit" in next ? next.lit : null;
      for (let end = pos; end <= text3.length && found.size < 2; end++) {
        if (literalNext !== null && !text3.startsWith(literalNext, end)) continue;
        walk(index + 1, end, { ...bound, [token.arg]: { text: text3.slice(pos, end), spec: token.spec, conv: token.conv } });
      }
    };
    walk(0, 0, {});
    if (found.size > 1 || steps > STEP_LIMIT) return { ambiguous: true };
    return { values: [...found.values()] };
  }
  var sameFormat = (a, b) => a.spec === b.spec && a.conv === b.conv;
  var plainCount = (token) => token.spec === PLAIN_SPEC && PLAIN_CONVERSIONS.includes(token.conv);
  function renderPythonFormat(edit, segment, raw) {
    const { msgid } = splitKey(edit.key);
    const plural = typeof edit.msgid_plural === "string";
    const baseForms = edit.from_forms ?? [edit.from];
    let draftTemplate;
    let baseTemplate;
    let count = null;
    if (plural) {
      const { __n: n, __form: form } = segment.args ?? {};
      if (typeof n !== "number" || !Number.isInteger(form) || form < 0) return { ok: false, reason: "unsupported" };
      const draft2 = pickPluralTemplate(edit.forms, msgid, edit.msgid_plural, n, form, "django");
      if (!draft2.ok) return draft2;
      const base2 = pickPluralTemplate(baseForms, msgid, edit.msgid_plural, n, form, "django");
      if (!base2.ok || typeof base2.template !== "string") return { ok: false, reason: "unsupported" };
      draftTemplate = draft2.template;
      baseTemplate = base2.template;
      count = n;
    } else {
      draftTemplate = edit.forms[0] === "" || edit.forms[0] === void 0 ? msgid : edit.forms[0];
      baseTemplate = baseForms[0] === "" || baseForms[0] === void 0 ? msgid : baseForms[0];
    }
    const base = tokenize2(baseTemplate);
    if (!base.tokens) return { ok: false, reason: "unsupported" };
    const draft = tokenize2(draftTemplate);
    if (!draft.tokens) return draft.reason === "invalid" ? { ok: false, reason: "invalid" } : { ok: false, reason: "unsupported" };
    const atoms = atomize(raw);
    const matched = captures(base.tokens, atoms ? atoms.text : raw);
    if (matched.ambiguous) return { ok: false, reason: "unsupported" };
    if (matched.values.length === 0) return { ok: false, reason: "mismatch" };
    const values = matched.values[0];
    if (atoms) for (const value of Object.values(values)) value.text = atoms.restore(value.text);
    let countName = null;
    const pluralNames = /* @__PURE__ */ new Map();
    if (plural) {
      const named = tokenize2(edit.msgid_plural);
      if (!named.tokens) return { ok: false, reason: "unsupported" };
      for (const token of named.tokens) if ("arg" in token) pluralNames.set(token.arg, token.conv);
      const integers = [...pluralNames].filter(([, conv]) => INTEGER_CONVERSIONS.includes(conv));
      if (pluralNames.size === 1) countName = [...pluralNames.keys()][0];
      else if (integers.length === 1) countName = integers[0][0];
    }
    let text3 = "";
    const used = /* @__PURE__ */ new Set();
    for (const token of draft.tokens) {
      if ("lit" in token) {
        text3 += token.lit;
        continue;
      }
      used.add(token.arg);
      if (Object.hasOwn(values, token.arg)) {
        const shown = values[token.arg];
        const exempt = token.arg === countName && plainCount(token) && plainCount(shown);
        if (!exempt && !sameFormat(token, shown)) return { ok: false, reason: "unsupported" };
        text3 += shown.text;
      } else if (token.arg === countName) {
        if (!plainCount(token)) return { ok: false, reason: "unsupported" };
        text3 += String(count);
      } else {
        return { ok: false, reason: pluralNames.has(token.arg) ? "unsupported" : "unknown_argument" };
      }
    }
    for (const name of Object.keys(values)) {
      if (!used.has(name) && name !== countName) return { ok: false, reason: "invalid" };
    }
    return { ok: true, text: text3 };
  }

  // js/in_context/gettext.js
  function bindingsOf(args, plural) {
    const bindings = {};
    for (const [name, value] of Object.entries(args)) {
      if (!name.startsWith("__")) bindings[name] = value;
    }
    if (plural && typeof args.__n === "number") bindings.count = args.__n;
    return bindings;
  }
  var text = (value) => value === null || value === void 0 ? "" : String(value);
  function interpolate(template, bindings) {
    let out = "";
    let rest = template;
    const missing = [];
    for (; ; ) {
      const start = rest.indexOf("%{");
      if (start < 0) return { text: out + rest, missing };
      const before = rest.slice(0, start);
      const after = rest.slice(start + 2);
      if (after.startsWith("}")) {
        out += `${before}%{}`;
        rest = after.slice(1);
        continue;
      }
      const end = after.indexOf("}");
      if (end < 0) return { text: out + rest, missing };
      const name = after.slice(0, end);
      if (Object.hasOwn(bindings, name)) {
        out += before + text(bindings[name]);
      } else {
        missing.push(name);
        out += `${before}%{${name}}`;
      }
      rest = after.slice(end + 1);
    }
  }
  var isGettextEdit = (edit) => Array.isArray(edit?.forms);
  function renderGettext(edit, segment, raw = "") {
    if (usesPythonFormat(edit)) return renderPythonFormat(edit, segment, raw);
    if (!segment.args) return { ok: false, reason: "unsupported" };
    const args = reviveArgs(segment.args, raw);
    const plural = typeof edit.msgid_plural === "string";
    const { msgid } = splitKey(edit.key);
    let template;
    if (plural) {
      const { __n: n, __form: form } = args;
      if (typeof n !== "number" || !Number.isInteger(form) || form < 0) return { ok: false, reason: "unsupported" };
      const picked = pickPluralTemplate(edit.forms, msgid, edit.msgid_plural, n, form);
      if (!picked.ok) return picked;
      template = picked.template;
    } else {
      template = edit.forms[0] === "" || edit.forms[0] === void 0 ? msgid : edit.forms[0];
    }
    const { text: rendered, missing } = interpolate(template, bindingsOf(args, plural));
    return missing.length ? { ok: false, reason: "invalid" } : { ok: true, text: rendered };
  }

  // js/in_context/transform.js
  var MAX_DEPTH = 8;
  var MAX_TEXT = 280;
  function transformValue(base, getEdit, format = null) {
    const results = [];
    const value = transform(base, getEdit, format, results, 0);
    return { value, results };
  }
  function isHtmlSegment(segment, raw) {
    return Boolean(segment.args) && reviveArgs(segment.args, raw).__html === true;
  }
  function transform(base, getEdit, format, results, depth) {
    const segments = parseSegments(base);
    return segments.length ? rebuild(base, 0, base.length, segments, getEdit, format, results, depth) : base;
  }
  function rebuild(base, from, to, segments, getEdit, format, results, depth) {
    let out = "";
    let pos = from;
    for (const segment of segments) {
      out += base.slice(pos, segment.start);
      const head = base.slice(segment.start, segment.innerStart);
      const tail = segment.open ? "" : CLOSE;
      let inner = null;
      const edit = getEdit(segment);
      if (edit) {
        const raw = base.slice(segment.innerStart, segment.innerEnd);
        const result = isHtmlSegment(segment, raw) ? { ok: false, reason: "mismatch" } : isGettextEdit(edit) ? renderGettext(edit, segment, raw) : renderWithArgs(edit.to, segment, raw, format) ?? previewText(edit.from, edit.to, raw);
        results.push({
          domain: segment.domain,
          key: segment.key,
          locale: segment.locale,
          ok: result.ok,
          reason: result.reason,
          text: result.ok ? stripMarks(result.text).slice(0, MAX_TEXT) : void 0
        });
        if (result.ok) {
          inner = depth < MAX_DEPTH ? transform(result.text, getEdit, format, results, depth + 1) : result.text;
        }
      }
      if (inner === null) {
        inner = rebuild(base, segment.innerStart, segment.innerEnd, segment.children, getEdit, format, results, depth);
      }
      out += head + inner + tail;
      pos = segment.end;
    }
    return out + base.slice(pos, to);
  }

  // js/in_context/preview.js
  function createPreview({
    scanner,
    onStatus = () => {
    },
    onEdits = () => {
    },
    onApplied = () => {
    },
    format = pageFormatter
  }) {
    let edits = /* @__PURE__ */ new Map();
    const reported = /* @__PURE__ */ new Map();
    const canvasTally = /* @__PURE__ */ new Map();
    const lookup = (segment) => edits.get(keyId(segment.domain, segment.key, segment.locale));
    const run = (value) => transformValue(value, lookup, format());
    function applySlot(slot) {
      const base = baseValue(slot);
      const { value } = run(base);
      setSlotValue(slot, base, value);
      scanner.refresh(slot);
    }
    function slotsFor(ids) {
      const out = [];
      for (const slot of scanner.slots()) {
        if (slot.occurrences.some((occ) => ids.has(keyId(occ.domain, occ.key, occ.locale)))) out.push(slot);
      }
      return out;
    }
    function statusOf(id) {
      let ok = 0;
      let fail = 0;
      let text3;
      let reason;
      const note = (result) => {
        if (result.ok) {
          ok += 1;
          text3 ?? (text3 = result.text);
        } else {
          fail += 1;
          reason ?? (reason = result.reason);
        }
      };
      for (const slot of scanner.slots()) {
        for (const result of run(baseValue(slot)).results) {
          if (keyId(result.domain, result.key, result.locale) === id) note(result);
        }
      }
      const canvas = canvasTally.get(id);
      if (canvas) {
        ok += canvas.ok;
        fail += canvas.fail;
        text3 ?? (text3 = canvas.text);
        reason ?? (reason = canvas.reason);
      }
      const status = { applied: ok > 0 && fail === 0, unsupported: fail > 0 };
      if (text3 !== void 0) status.text = text3;
      if (fail > 0 && reason) status.reason = reason;
      return status;
    }
    function report(id, force) {
      const edit = edits.get(id);
      if (!edit) return;
      const status = statusOf(id);
      const signature = `${status.applied}|${status.unsupported}|${status.reason ?? ""}|${status.text ?? ""}`;
      if (!force && reported.get(id) === signature) return;
      reported.set(id, signature);
      onStatus({ domain: edit.domain, key: edit.key, locale: edit.locale, ...status });
    }
    function commit(ids, { force }) {
      for (const slot of slotsFor(ids)) applySlot(slot);
      for (const id of ids) report(id, force);
      onEdits([...edits.values()]);
      onApplied();
    }
    const idOf = (edit) => keyId(edit.domain, edit.key, edit.locale);
    return {
      /** Set or replace one live preview. */
      set(edit) {
        const id = idOf(edit);
        edits.set(id, edit);
        canvasTally.delete(id);
        commit(/* @__PURE__ */ new Set([id]), { force: true });
      },
      /** Restore the original text of one message. */
      clear(identity2) {
        const id = idOf(identity2);
        if (!edits.delete(id)) return;
        reported.delete(id);
        canvasTally.delete(id);
        commit(/* @__PURE__ */ new Set([id]), { force: false });
      },
      /** Replace the whole preview set. */
      reset(list) {
        const previous = new Set(edits.keys());
        edits = new Map(list.map((edit) => [idOf(edit), edit]));
        const affected = /* @__PURE__ */ new Set([...previous, ...edits.keys()]);
        for (const id of previous) {
          reported.delete(id);
          canvasTally.delete(id);
        }
        commit(affected, { force: true });
      },
      /** Slots the scanner just found or the host re-rendered: re-apply active edits. */
      applyToSlots(slots) {
        if (!edits.size) return;
        const touched = /* @__PURE__ */ new Set();
        for (const slot of slots) {
          if (!slot.isConnected()) continue;
          applySlot(slot);
          for (const occ of slot.occurrences ?? []) touched.add(keyId(occ.domain, occ.key, occ.locale));
        }
        for (const id of touched) if (edits.has(id)) report(id, false);
        onApplied();
      },
      /** The page's formatter just became available: re-render every preview with it. */
      reapply() {
        if (edits.size) commit(new Set(edits.keys()), { force: false });
      },
      /** Canvas draw hook: a marked string about to be drawn. */
      transformString(text3) {
        return edits.size ? run(text3) : { value: text3, results: [] };
      },
      noteCanvasResults(results) {
        const fresh = /* @__PURE__ */ new Map();
        for (const result of results) {
          const id = keyId(result.domain, result.key, result.locale);
          const tally = fresh.get(id) ?? { ok: 0, fail: 0 };
          if (result.ok) {
            tally.ok += 1;
            tally.text ?? (tally.text = result.text);
          } else {
            tally.fail += 1;
            tally.reason ?? (tally.reason = result.reason);
          }
          fresh.set(id, tally);
        }
        for (const [id, tally] of fresh) {
          canvasTally.set(id, tally);
          if (edits.has(id)) report(id, false);
        }
      },
      edits: () => [...edits.values()],
      size: () => edits.size
    };
  }

  // js/in_context/save.js
  async function saveFiles(endpoint, edits, { fetchImpl = globalThis.fetch?.bind(globalThis) } = {}) {
    if (!endpoint || !fetchImpl) return { error: "unavailable" };
    try {
      const response = await fetchImpl(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ edits }),
        credentials: "same-origin"
      });
      if (!response.ok) return { error: `status_${response.status}` };
      return await response.json();
    } catch {
      return { error: "unreachable" };
    }
  }

  // js/in_context/site.js
  var SITE_TIMEOUT_MS = 2e3;
  var REPO = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
  var SHA = /^[0-9a-f]{7,64}$/i;
  var ADDON = /^([a-z][a-z0-9_-]{0,30}@)?\d+\.\d+\.\d+$/;
  var MAX_PROJECT = 200;
  var MAX_BRANCH = 255;
  var MAX_PATH = 512;
  var MAX_DIRTY = 200;
  var text2 = (value, max) => typeof value === "string" && value !== "" && value.length <= max ? value : null;
  function normalizeSite(raw, fallbackProject = "") {
    const context = raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
    const dirty = Array.isArray(context.dirty) ? context.dirty.filter((path) => text2(path, MAX_PATH)).slice(0, MAX_DIRTY) : [];
    return {
      repo: typeof context.repo === "string" && REPO.test(context.repo) ? context.repo : null,
      project: text2(context.project, MAX_PROJECT) ?? (fallbackProject || null),
      branch: text2(context.branch, MAX_BRANCH),
      sha: typeof context.sha === "string" && SHA.test(context.sha) ? context.sha.toLowerCase() : null,
      dirty,
      addon: typeof context.addon === "string" && ADDON.test(context.addon) ? context.addon : null,
      ...context.save === true ? { save: true } : {}
    };
  }
  async function loadSite(path, { fetchImpl = globalThis.fetch, timeoutMs = SITE_TIMEOUT_MS, fallbackProject = "" } = {}) {
    const fallback = () => normalizeSite(null, fallbackProject);
    if (!path || typeof fetchImpl !== "function") return fallback();
    const controller = new AbortController();
    let timer = 0;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => {
        controller.abort();
        resolve(null);
      }, timeoutMs);
    });
    const request = (async () => {
      const response = await fetchImpl(path, {
        credentials: "same-origin",
        cache: "no-store",
        headers: { accept: "application/json" },
        signal: controller.signal
      });
      return response.ok ? await response.json() : null;
    })().catch(() => null);
    try {
      return normalizeSite(await Promise.race([request, timeout]), fallbackProject);
    } finally {
      clearTimeout(timer);
    }
  }

  // js/in_context/snapshot.js
  var KIND_ORDER = ["text", "attribute", "title", "meta", "canvas"];
  var MAX_TEXT2 = 280;
  function clip(text3) {
    const clean = text3.replace(/\s+/g, " ").trim();
    return clean.length > MAX_TEXT2 ? `${clean.slice(0, MAX_TEXT2 - 1)}\u2026` : clean;
  }
  function aggregate(occurrences) {
    const rows = /* @__PURE__ */ new Map();
    for (const occ of occurrences) {
      const id = keyId(occ.domain, occ.key, occ.locale);
      let row = rows.get(id);
      if (!row) {
        const { msgctxt } = splitKey(occ.key);
        row = {
          domain: occ.domain,
          key: occ.key,
          locale: occ.locale,
          ...msgctxt === null ? {} : { msgctxt },
          text: clip(occ.text ?? ""),
          count: 0,
          on_screen: false,
          kinds: /* @__PURE__ */ new Set()
        };
        rows.set(id, row);
      }
      row.count += 1;
      row.on_screen = row.on_screen || occ.onScreen === true;
      row.kinds.add(occ.kind);
    }
    return [...rows.values()].map((row) => ({
      ...row,
      kinds: KIND_ORDER.filter((kind) => row.kinds.has(kind))
    }));
  }

  // js/in_context/stop.js
  var TOKEN_PARAM = "dialecto_edit";
  function stopUrl(value, origin) {
    if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return null;
    try {
      const url = new URL(value, origin);
      return url.origin === origin ? url.href : null;
    } catch {
      return null;
    }
  }
  function cleanUrl(href) {
    const url = new URL(href);
    url.searchParams.delete(TOKEN_PARAM);
    return url.href;
  }
  async function stopEditing(url, { fetch = globalThis.fetch, location: location2 = globalThis.location } = {}) {
    try {
      const response = await fetch(url, { method: "POST", credentials: "same-origin", cache: "no-store" });
      if (!response.ok) return false;
    } catch {
      return false;
    }
    location2.replace(cleanUrl(location2.href));
    return true;
  }

  // js/in_context/toggle.js
  var HIDDEN_KEY = "dialecto-in-context:hidden";
  var SHORTCUT_KEY = "dialecto-in-context:shortcut";
  var DEFAULT_SHORTCUT = "alt+shift+d";
  var ALIASES = { option: "alt", control: "ctrl", cmd: "meta", command: "meta" };
  var ORDER = ["ctrl", "alt", "shift", "meta"];
  var OS_TAKEN = /* @__PURE__ */ new Set(["d", "h", "m", "w", "i", "j", "c", "u", "b"]);
  var typing = (target) => target?.isContentEditable === true || /^(INPUT|TEXTAREA|SELECT)$/.test(target?.tagName ?? "");
  function parseCombo(value) {
    if (typeof value !== "string") return null;
    const mods = /* @__PURE__ */ new Set();
    let key = null;
    for (const raw of value.split("+")) {
      const token = raw.trim().toLowerCase();
      const name = ALIASES[token] ?? token;
      if (ORDER.includes(name)) {
        if (mods.has(name)) return null;
        mods.add(name);
      } else if (/^([a-z0-9]|f([1-9]|1[0-2]))$/.test(token) && key === null) {
        key = token;
      } else {
        return null;
      }
    }
    if (key === null) return null;
    if (!mods.has("alt") || mods.has("ctrl") && !mods.has("meta")) return null;
    if (mods.has("meta") && OS_TAKEN.has(key)) return null;
    return { ...Object.fromEntries(ORDER.map((m) => [m, mods.has(m)])), key };
  }
  function canonicalCombo(value) {
    const combo = parseCombo(value);
    return combo ? [...ORDER.filter((m) => combo[m]), combo.key].join("+") : "";
  }
  var codeOf = (key) => /^\d$/.test(key) ? `Digit${key}` : /^f/.test(key) && key.length > 1 ? key.toUpperCase() : `Key${key.toUpperCase()}`;
  function isToggle(event, value) {
    const combo = parseCombo(value);
    return combo !== null && event.code === codeOf(combo.key) && Boolean(event.ctrlKey) === combo.ctrl && Boolean(event.altKey) === combo.alt && Boolean(event.shiftKey) === combo.shift && Boolean(event.metaKey) === combo.meta && !event.repeat && !typing(event.target);
  }
  var MAC_SYMBOLS = { ctrl: "\u2303", alt: "\u2325", shift: "\u21E7", meta: "\u2318" };
  var PC_NAMES = { ctrl: "Ctrl", alt: "Alt", shift: "Shift", meta: "Meta" };
  var isMac = () => /Mac|iPhone|iPad/.test(globalThis.navigator?.platform ?? "");
  function displayCombo(value, mac = isMac()) {
    const combo = parseCombo(value);
    if (!combo) return "";
    const mods = ORDER.filter((m) => combo[m]);
    const key = combo.key.toUpperCase();
    return mac ? `${mods.map((m) => MAC_SYMBOLS[m]).join("")}${key}` : [...mods.map((m) => PC_NAMES[m]), key].join("+");
  }
  function readShortcut(storage = globalThis.localStorage) {
    try {
      return canonicalCombo(storage?.getItem(SHORTCUT_KEY));
    } catch {
      return "";
    }
  }
  function writeShortcut(value, storage = globalThis.localStorage) {
    const combo = canonicalCombo(value);
    try {
      if (combo) storage?.setItem(SHORTCUT_KEY, combo);
      else storage?.removeItem(SHORTCUT_KEY);
    } catch {
    }
    return combo !== "";
  }
  function readHidden(storage = globalThis.sessionStorage, fallback = false) {
    try {
      const stored = storage?.getItem(HIDDEN_KEY);
      return stored === "1" ? true : stored === "0" ? false : fallback;
    } catch {
      return fallback;
    }
  }
  function writeHidden(hidden, storage = globalThis.sessionStorage) {
    try {
      storage?.setItem(HIDDEN_KEY, hidden ? "1" : "0");
    } catch {
    }
  }

  // js/in_context/overlay.js
  var script = document.currentScript;
  var CORNERS = ["bottom-right", "bottom-left", "top-right", "top-left"];
  var flag = (value) => value === true || value === "true" ? true : value === false || value === "false" ? false : void 0;
  function readConfig() {
    const global = window.DIALECTO_IN_CONTEXT ?? {};
    const data = script?.dataset ?? {};
    return {
      url: data.url || global.url || "",
      // `repo` is what older add-on copies call the project.
      project: data.project || data.repo || global.project || global.repo || "",
      context: data.context ?? global.context ?? "",
      overrides: data.overrides ?? global.overrides ?? "",
      // Only the Phoenix add-on names one (spec-0017 §1.3).
      marking: data.marking ?? global.marking ?? "",
      // Live mode only: when the editor's launch token ends (unix seconds), so the
      // sign-in asked for here ends no later (spec-0025 §5).
      exp: Number.parseInt(data.exp ?? global.exp ?? "", 10),
      // Live mode only, and only from the add-on's own loader tag: the route that ends the session.
      stop: data.stop ?? "",
      // The project's shortcut. Any value, even an unusable one (an older add-on's bare letter), still means the
      // page opens hidden, as it did when that was the only shortcut.
      toggleKey: canonicalCombo(data.toggleKey ?? global.toggleKey),
      // Opens hidden until the shortcut; without it the tab's own choice, then `toggleKey`'s presence, decides.
      hidden: flag(data.hidden ?? global.hidden) ?? (String(data.toggleKey ?? global.toggleKey ?? "").trim() !== "" ? true : void 0),
      corner: CORNERS.includes(data.corner ?? global.corner) ? data.corner ?? global.corner : "bottom-right",
      // Only from the add-on's own loader tag: where its dev server saves drafts to files.
      save: data.save ?? ""
    };
  }
  function install() {
    if (window.DialectoInContext) return;
    const config = readConfig();
    if (!config.url) {
      console.warn("[dialecto] in-context overlay needs a Dialecto URL; not started.");
      return;
    }
    let base;
    try {
      base = new URL(config.url);
    } catch {
      console.warn(`[dialecto] in-context overlay: "${config.url}" is not a valid URL; not started.`);
      return;
    }
    const sitePromise = config.context ? loadSite(config.context, { fallbackProject: config.project }) : Promise.resolve(normalizeSite(null, config.project));
    let site = normalizeSite(null, config.project);
    const statuses = /* @__PURE__ */ new Map();
    let host = null;
    let panel = null;
    let bridge = null;
    let pendingPick = null;
    let measureFrame = 0;
    const isOwn = (node) => Boolean(host) && (node === host || host.contains(node));
    const viewport = () => ({ left: 0, top: 0, right: panel ? panel.usableRight() : window.innerWidth, bottom: window.innerHeight });
    const scanner = createScanner({
      isIgnored: isOwn,
      viewport,
      onChange: (slots) => {
        preview.applyToSlots(slots);
        scheduleMeasure();
        bridge?.requestSnapshot();
      }
    });
    const overrides = createOverrideSync(config.overrides);
    window.addEventListener("formdata", (event) => stripFormData(event.formData), { capture: true });
    const preview = createPreview({
      scanner,
      onStatus: (status) => {
        statuses.set(keyId(status.domain, status.key, status.locale), status);
        bridge?.sendPreviewStatus(status);
      },
      onEdits: (edits) => overrides.push(edits),
      onApplied: () => {
        scheduleMeasure();
        bridge?.requestSnapshot();
      }
    });
    window.addEventListener("dialecto:formatter", () => preview.reapply());
    const canvas = installCanvas({
      transform: (text3) => preview.transformString(text3),
      onResults: (results) => preview.noteCanvasResults(results),
      onSeen: () => {
        scheduleMeasure();
        bridge?.requestSnapshot();
      }
    });
    const marking = createMarking(config.marking, {
      hasMarkers: () => scanner.occurrences().length > 0 || canvas.occurrences().length > 0
    });
    let scanned = false;
    function currentStrings() {
      scanner.measure();
      canvas.measure(viewport());
      return aggregate([...scanner.occurrences(), ...canvas.occurrences()]);
    }
    function scheduleMeasure() {
      if (measureFrame) return;
      measureFrame = requestAnimationFrame(() => {
        measureFrame = 0;
        const textChanged = scanner.measure();
        const canvasChanged = canvas.measure(viewport());
        if (textChanged || canvasChanged) bridge?.requestSnapshot();
        highlighter?.schedule();
      });
    }
    let highlighter = null;
    let picker = null;
    let hidden = readHidden(void 0, config.hidden === true);
    let reopen = false;
    let own = readShortcut();
    const baseShortcut = () => config.toggleKey || DEFAULT_SHORTCUT;
    const activeShortcut = () => own || baseShortcut();
    function setHidden(next) {
      if (next === hidden) return;
      hidden = next;
      writeHidden(hidden);
      if (scanned) applyHidden();
    }
    function setShortcut(value) {
      const next = canonicalCombo(value);
      if (value !== "" && next === "") return;
      own = next;
      writeShortcut(next);
      panel?.setShortcut(displayCombo(activeShortcut()));
    }
    function applyHidden() {
      if (hidden && document.activeElement === host) host.shadowRoot.activeElement?.blur();
      host.style.display = hidden ? "none" : "";
      picker.setPaused(hidden);
      if (hidden) {
        reopen = panel.isOpen();
        if (reopen) panel.close();
      } else if (reopen) {
        reopen = false;
        panel.open();
      }
    }
    window.addEventListener(
      "keydown",
      (event) => {
        if (!isToggle(event, activeShortcut())) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        setHidden(!hidden);
      },
      { capture: true }
    );
    function handleMessage(message) {
      switch (message.type) {
        case "ready":
          panel.showReady();
          preview.reset(message.edits);
          if (pendingPick) {
            bridge.sendPick(pendingPick.domain, pendingPick.key);
            pendingPick = null;
          }
          break;
        case "preview":
          preview.set(message);
          break;
        case "preview_clear":
          preview.clear(message);
          break;
        case "previews_reset":
          preview.reset(message.edits);
          break;
        case "highlight":
          highlighter.setTarget(message.domain === null ? null : { domain: message.domain, key: message.key }, { scroll: message.scroll });
          break;
        case "pick_mode":
          picker.setPickMode(message.on);
          break;
        case "save_files":
          saveFiles(config.save, message.edits).then((result) => bridge.sendFilesSaved(result));
          break;
        case "close":
          panel.close();
          break;
        case "toggle":
          setHidden(!hidden);
          break;
        case "shortcut":
          setShortcut(message.key);
          break;
        case "reload":
          location.reload();
          break;
      }
    }
    async function start() {
      host = document.createElement("div");
      host.setAttribute("data-dialecto-host", "");
      host.style.cssText = "all: initial";
      const root = host.attachShadow({ mode: "open" });
      document.documentElement.append(host);
      site = await sitePromise;
      if (Number.isSafeInteger(config.exp) && config.exp > 0) site = { ...site, exp: config.exp };
      const src = sidebarUrl(base, { site: site.repo, project: site.project, locale: document.documentElement.lang });
      highlighter = createHighlighter({ root, scanner, canvas, getViewport: viewport, onTab: () => picker.pickHover() });
      picker = createPicker({
        scanner,
        canvas,
        highlighter,
        isInside: isOwn,
        isEditing: () => panel?.isOpen() === true,
        onPick: ({ domain, key }) => {
          if (bridge.isReady()) {
            bridge.sendPick(domain, key);
          } else {
            pendingPick = { domain, key };
            panel.open();
          }
        }
      });
      const stopRoute = stopUrl(config.stop, location.origin);
      panel = createPanel({
        root,
        corner: config.corner,
        src,
        dialectoUrl: base.origin,
        siteOrigin: location.origin,
        onFrameLoad: () => bridge.startHandshake(),
        onRetry: () => bridge.startHandshake(),
        onStop: stopRoute ? () => stopEditing(stopRoute) : null,
        onOpenChange: (open) => {
          scheduleMeasure();
          picker.refresh();
          if (scanned) marking.setOpen(open);
        }
      });
      bridge = createBridge({
        origin: base.origin,
        frameWindow: () => panel.frameWindow(),
        page: () => ({ url: location.href, title: stripMarks(document.title), locale: document.documentElement.lang }),
        site: () => site,
        strings: currentStrings,
        onMessage: handleMessage,
        onTimeout: () => panel.showError(),
        toggleKey: activeShortcut,
        baseKey: baseShortcut
      });
      panel.setShortcut(displayCombo(activeShortcut()));
      const initial = scanner.start();
      if (initial.length) preview.applyToSlots(initial);
      scheduleMeasure();
      scanned = true;
      marking.setOpen(panel.isOpen());
      if (hidden) applyHidden();
      window.addEventListener("scroll", scheduleMeasure, { passive: true, capture: true });
      window.addEventListener("resize", scheduleMeasure, { passive: true });
      window.addEventListener("transitionend", scheduleMeasure, { passive: true, capture: true });
      window.addEventListener("animationend", scheduleMeasure, { passive: true, capture: true });
      if (typeof ResizeObserver === "function") new ResizeObserver(scheduleMeasure).observe(document.documentElement);
    }
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
    else start();
    window.DialectoInContext = {
      open: () => panel?.open(),
      close: () => panel?.close(),
      show: () => setHidden(false),
      hide: () => setHidden(true),
      strings: () => currentStrings(),
      preview(edit) {
        preview.set(edit);
        return statuses.get(keyId(edit.domain, edit.key, edit.locale)) ?? null;
      },
      clearPreviews: () => preview.reset([]),
      edits: () => preview.edits()
    };
  }
  install();
})();
