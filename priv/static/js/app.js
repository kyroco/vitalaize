// Wallboard in the browser: the live connection, the clock and ages, page
// rotation, swipes, and fitting the 1366 x 1024 design to the screen.
(() => {
  const board = () => document.getElementById("board");
  const tz = () => (board() && board().dataset.tz) || "America/New_York";

  // ---- Times ---------------------------------------------------------------
  // The server sends timestamps; this writes them as "1:27 PM", "4m ago" or
  // "4m", in the board's time zone, and keeps them ticking.
  let clockFmt, hourFmt, dayFmt;
  const makeFormats = () => {
    clockFmt = new Intl.DateTimeFormat("en-US", { timeZone: tz(), hour: "numeric", minute: "2-digit" });
    hourFmt = new Intl.DateTimeFormat("en-US", { timeZone: tz(), hour: "numeric", minute: "2-digit" });
    dayFmt = new Intl.DateTimeFormat("en-US", { timeZone: tz(), weekday: "long", month: "numeric", day: "numeric" });
  };
  const MONTHS = ["Jan", "Feb", "March", "April", "May", "June", "July", "Aug", "Sept", "Oct", "Nov", "Dec"];

  const span = (secs) => {
    secs = Math.max(0, Math.round(secs));
    if (secs < 60) return secs + "s";
    const m = Math.floor(secs / 60);
    if (m < 60) return m + "m";
    const h = Math.floor(m / 60);
    if (h < 48) return h + "h " + (m % 60) + "m";
    return Math.floor(h / 24) + "d";
  };

  const hourText = (d) => hourFmt.format(d).replace(":00", "");
  // "9:03 AM" today, "Sept 28, 9:03 AM" on another day.
  const whenText = (d, now) => {
    const md = (x) => {
      const p = Object.fromEntries(dayFmt.formatToParts(x).map((q) => [q.type, q.value]));
      return `${MONTHS[parseInt(p.month, 10) - 1]} ${p.day}`;
    };
    const day = md(d);
    return (day === md(now) ? "" : day + ", ") + clockFmt.format(d);
  };

  const formatEl = (el, now) => {
    const d = new Date(el.dataset.ts);
    if (isNaN(d)) return;
    const age = (now - d) / 1000;
    let text;
    switch (el.dataset.fmt) {
      case "clock": text = clockFmt.format(d); break;
      case "hour": text = hourText(d); break;
      case "for": text = span(age); break;
      case "when": text = whenText(d, now); break;
      default: text = age < 5 ? "just now" : span(age) + " ago";
    }
    if (el.textContent !== text) el.textContent = text;
    const staleAfter = parseInt(el.dataset.stale || "0", 10);
    el.classList.toggle("stale", staleAfter > 0 && age > staleAfter);
  };

  const today = (now) => {
    const parts = Object.fromEntries(dayFmt.formatToParts(now).map((p) => [p.type, p.value]));
    return `${parts.weekday}, ${MONTHS[parseInt(parts.month, 10) - 1]} ${parts.day}`;
  };

  // Lists that can run out of room ([data-clip]) show only the rows that fit
  // whole, never a row cut in half.
  const clipRows = () => {
    document.querySelectorAll("[data-clip]").forEach((box) => {
      const limit = box.clientHeight;
      Array.from(box.children).forEach((row) => {
        row.style.visibility = "";
        if (row.offsetTop + row.offsetHeight > limit + 1) row.style.visibility = "hidden";
      });
    });
  };

  const tick = () => {
    if (!clockFmt) makeFormats();
    clipRows();
    const now = new Date();
    document.querySelectorAll("[data-ts]").forEach((el) => formatEl(el, now));
    document.querySelectorAll("[data-clock]").forEach((el) => { el.textContent = clockFmt.format(now); });
    document.querySelectorAll("[data-today]").forEach((el) => { el.textContent = today(now); });
  };

  // ---- Fit to screen -------------------------------------------------------
  // Drawn at 1366 x 1024 like the mockups, then scaled so it fills the
  // screen: landscape keeps 1024 tall and grows wider as needed.
  const fit = () => {
    const el = board();
    if (!el) return;
    const w = window.innerWidth, h = window.innerHeight;
    const s = Math.min(w / 1366, h / 1024);
    el.style.setProperty("--scale", s);
    el.style.setProperty("--canvas-w", w / s + "px");
    el.style.setProperty("--canvas-h", h / s + "px");
  };

  // ---- Pages ---------------------------------------------------------------
  let page = 0, timer = null;

  const pageCount = () => parseInt((board() && board().dataset.pages) || "2", 10);

  const show = (n, instant) => {
    const count = pageCount();
    page = (n + count) % count;
    const track = document.getElementById("track");
    // Each page's header already marks its own dot, so only the track moves.
    if (track) {
      track.style.transition = instant ? "none" : "";
      track.style.transform = `translateX(${page * -50}%)`;
    }
    restartTimer();
  };

  // Pinned: the pages stop rotating until the pin is tapped again. Swiping
  // still flips by hand. Each device remembers its own choice.
  // ---- Light or dark ------------------------------------------------------
  // Each device keeps its own choice, like Pin. With none it follows the
  // device's own mode.
  const darkNow = () => {
    const t = document.documentElement.dataset.theme;
    if (t) return t === "dark";
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  };
  const drawTheme = () => {
    const dark = darkNow();
    document.querySelectorAll("[data-theme-toggle]").forEach((b) => {
      b.classList.toggle("dark", dark);
      const word = b.querySelector(".theme-word");
      if (word) word.textContent = dark ? "Light" : "Dark";
    });
  };
  const toggleTheme = () => {
    const next = darkNow() ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem("wallboard-theme", next); } catch (_) {}
    drawTheme();
  };
  if (window.matchMedia) window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", drawTheme);

  // ---- Bar values -----------------------------------------------------------
  // Hovering a bar with a mouse, or tapping it on the iPad, shows its value.
  // Another tap on the same bar, or a tap anywhere else, hides it.
  let tip = null, tipOn = null;
  const tipFor = (bar) => {
    if (tipOn) {
      tipOn.classList.remove("on");
      const s = tipOn.closest(".spark");
      if (s) s.classList.remove("reading");
    }
    tipOn = bar && document.contains(bar) ? bar : null;
    if (!tip) {
      tip = document.createElement("div");
      tip.className = "bar-tip";
      tip.hidden = true;
      document.body.appendChild(tip);
    }
    if (!tipOn) { tip.hidden = true; return; }
    tipOn.classList.add("on");
    tipOn.closest(".spark").classList.add("reading");
    const box = tipOn.getBoundingClientRect(), spark = tipOn.closest(".spark").getBoundingClientRect();
    tip.textContent = tipOn.dataset.tip;
    tip.hidden = false;
    const half = tip.offsetWidth / 2 + 4;
    tip.style.left = Math.min(Math.max(box.left + box.width / 2, half), window.innerWidth - half) + "px";
    tip.style.top = spark.top + "px";
  };
  document.addEventListener("mouseover", (e) => {
    if (e.sourceCapabilities && e.sourceCapabilities.firesTouchEvents) return;
    const bar = e.target.closest && e.target.closest("[data-tip]");
    if (bar !== tipOn) tipFor(bar);
  });

  let pinned = false;
  try { pinned = localStorage.getItem("wallboard-pinned") === "1"; } catch (_) {}

  const drawPin = () => {
    document.querySelectorAll("[data-pin]").forEach((b) => {
      b.classList.toggle("on", pinned);
      b.setAttribute("aria-pressed", pinned ? "true" : "false");
    });
  };

  const setPinned = (on) => {
    pinned = on;
    try { localStorage.setItem("wallboard-pinned", on ? "1" : "0"); } catch (_) {}
    drawPin();
    restartTimer();
  };

  const restartTimer = () => {
    clearInterval(timer);
    const secs = parseInt((board() && board().dataset.rotate) || "0", 10);
    if (secs > 0 && !pinned && pageCount() > 1) timer = setInterval(() => show(page + 1), secs * 1000);
  };

  const wireInput = () => {
    let x0 = null, y0 = null;
    document.addEventListener("touchstart", (e) => { x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; }, { passive: true });
    // A tap on the pin or a dot is handled right on the touch, and the
    // browser's own click that follows is cancelled, so it acts once.
    const tapControl = (target) => {
      if (target.closest("[data-pin]")) { setPinned(!pinned); return true; }
      if (target.closest("[data-theme-toggle]")) { toggleTheme(); return true; }
      const bar = target.closest("[data-tip]");
      if (bar) { tipFor(bar === tipOn ? null : bar); return true; }
      if (tipOn) tipFor(null);
      const dot = target.closest("[data-goto]");
      if (dot) { show(parseInt(dot.dataset.goto, 10)); return true; }
      return false;
    };
    document.addEventListener("touchend", (e) => {
      if (x0 === null) return;
      const dx = e.changedTouches[0].clientX - x0, dy = e.changedTouches[0].clientY - y0;
      x0 = null;
      if (Math.abs(dx) < 12 && Math.abs(dy) < 12) {
        if (tapControl(e.target)) e.preventDefault();
      } else if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
        show(page + (dx < 0 ? 1 : -1));
      }
    }, { passive: false });
    document.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight") show(page + 1);
      if (e.key === "ArrowLeft") show(page - 1);
    });
    document.addEventListener("click", (e) => {
      if (tapControl(e.target)) return;
      // Tapping the clock asks for full screen where the browser allows it.
      if (e.target.closest("[data-fullscreen]")) {
        const root = document.documentElement;
        const go = root.requestFullscreen || root.webkitRequestFullscreen;
        if (go && !document.fullscreenElement && !document.webkitFullscreenElement) go.call(root);
      }
    });
    // Keep the screen awake while the board is showing, where supported.
    const wake = () => navigator.wakeLock && navigator.wakeLock.request("screen").catch(() => {});
    document.addEventListener("click", wake, { once: true });
    document.addEventListener("touchend", wake, { once: true });
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") wake(); });
  };

  // ---- Live connection -----------------------------------------------------
  const Hooks = {
    Board: {
      // An address ending in #page2 opens on page 2.
      mounted() { makeFormats(); fit(); drawPin(); drawTheme(); show(location.hash === "#page2" ? 1 : page, true); tick(); },
      updated() {
        tick(); drawTheme();
        // LiveView may have swapped the bar out; follow it or hide the value.
        if (tipOn && !document.contains(tipOn)) tipFor(null);
        else if (tipOn) tipFor(tipOn);
      },
    },
  };

  window.addEventListener("DOMContentLoaded", () => {
    const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
    // Tells the board which app.css and app.js this page loaded, so after an
    // update it can reload a screen that is still running the old ones.
    const assetVersion = document.querySelector("meta[name='asset-version']").getAttribute("content");
    const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
      params: { _csrf_token: csrf, asset_version: assetVersion },
      hooks: Hooks,
      dom: {
        // Keep what the browser owns (the page position, the active dot) and
        // write times before they appear, so nothing flickers on an update.
        onBeforeElUpdated(from, to) {
          const keep = from.dataset && from.dataset.keep;
          if (keep) keep.split(" ").forEach((attr) => {
            const v = from.getAttribute(attr);
            if (v !== null) to.setAttribute(attr, v);
          });
          if (to.dataset && to.dataset.ts) formatEl(to, new Date());
          return true;
        },
      },
    });
    liveSocket.connect();
    wireInput();
    fit();
    tick();
    setInterval(tick, 1000);
  });
  window.addEventListener("resize", fit);
  window.addEventListener("orientationchange", () => setTimeout(fit, 200));
})();
