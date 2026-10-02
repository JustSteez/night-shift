(() => {
  const root = document.documentElement;
  const body = document.body;
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (id) => document.getElementById(id);

  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const smooth = (a, b, v) => { const t = clamp((v - a) / (b - a)); return t * t * (3 - 2 * t); };

  // ------------------------------------------------------------ the film: scroll moves the camera
  const chapters = [...document.querySelectorAll(".chapter")];
  const shots = [...document.querySelectorAll(".shot")];
  const LAST = chapters.length - 1;
  const stat = document.querySelector(".big-stat");
  let statDone = false;

  function chapterProgress(ch) {
    const r = ch.getBoundingClientRect();
    return clamp(-r.top / Math.max(1, r.height - innerHeight)) || 0;
  }

  function render() {
    let t = 0;
    chapters.forEach((ch, i) => {
      const p = chapterProgress(ch);
      const enter = i === 0 ? 1 : smooth(0.04, 0.2, p);
      const leave = i === LAST ? 0 : smooth(0.74, 0.92, p);
      const visible = enter * (1 - leave);
      ch.style.setProperty("--in", visible.toFixed(3));
      if (ch.getBoundingClientRect().top <= 1) t = i + p;
      if (ch.contains(stat) && visible > 0.6 && !statDone) countUp();
    });

    const k = Math.min(Math.floor(t), LAST);
    const fade = k === LAST ? 0 : smooth(0.8, 1, t - k);
    shots.forEach((img, j) => {
      const opacity = j === k ? 1 - fade : j === k + 1 ? fade : 0;
      const local = clamp(t - j + 0.25, 0, 1.25) / 1.25;
      img.style.opacity = opacity.toFixed(3);
      if (opacity > 0) img.style.transform = `scale(${(1.04 + local * 0.16).toFixed(4)}) translateY(${(-local * 2).toFixed(2)}%)`;
    });

    $("railTime").textContent = chapters[Math.min(Math.round(t - 0.3), LAST)]?.dataset.time ?? "";
    body.classList.toggle("scrolled", scrollY > 40);
    root.style.setProperty("--page", (scrollY / Math.max(1, root.scrollHeight - innerHeight)).toFixed(4));
  }

  function countUp() {
    statDone = true;
    const target = Number(stat.dataset.count);
    if (reduceMotion) { stat.textContent = `${target}%`; return; }
    const start = performance.now();
    const step = (now) => {
      const p = clamp((now - start) / 1400);
      stat.textContent = `${Math.round(target * (1 - Math.pow(1 - p, 3)))}%`;
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => { render(); ticking = false; });
  };
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);
  render();

  // ------------------------------------------------------------ the closing bell (synthesized, no audio files)
  let audio;
  $("bell").addEventListener("click", () => {
    const flash = document.querySelector(".flash");
    flash.classList.remove("go");
    void flash.offsetWidth;
    flash.classList.add("go");
    try {
      audio = audio || new AudioContext();
      const now = audio.currentTime;
      for (const [freq, gain] of [[523.25, 0.32], [1046.5, 0.16], [1567.98, 0.08], [2637, 0.04]]) {
        const osc = audio.createOscillator();
        const amp = audio.createGain();
        osc.frequency.value = freq;
        amp.gain.setValueAtTime(gain, now);
        amp.gain.exponentialRampToValueAtTime(0.0001, now + 2.6);
        osc.connect(amp).connect(audio.destination);
        osc.start(now);
        osc.stop(now + 2.7);
      }
    } catch (err) {
      console.warn("Bell audio unavailable:", err);
    }
  });

  // ------------------------------------------------------------ ticker ribbon
  const TICKERS = "TSLA +6.2%  ·  NVDA −3.1%  ·  HIMS +112%  ·  AAPL +0.8%  ·  AMD −1.2%  ·  PLTR +3.4%  ·  MSTR +6.9%  ·  GME +4.2%  ·  ";
  const ribbonText = $("ribbonText");
  ribbonText.textContent = TICKERS.repeat(4);
  if (!reduceMotion) {
    let offset = 0;
    const loop = ribbonText.getComputedTextLength() / 4;
    const tick = () => {
      offset = (offset - 0.6) % loop;
      ribbonText.setAttribute("startOffset", offset);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  // ------------------------------------------------------------ playground: same math as the contract
  // close = last NYSE close, premium = how far the onchain pool drifted, depth = pool liquidity in USD.
  const STOCKS = {
    HIMS: { close: 52.4, premium: 1.12, depth: 60_000 },
    TSLA: { close: 250, premium: 0.062, depth: 400_000 },
    NVDA: { close: 180, premium: -0.031, depth: 500_000 },
  };
  const usd = (n) => {
    const digits = n !== 0 && Math.abs(n) < 100 ? 2 : 0;
    return `${n < 0 ? "−" : ""}$${Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits })}`;
  };
  const pct = (n) => `${n >= 0 ? "+" : "−"}${Math.abs(n * 100).toFixed(1)}%`;
  let active = "HIMS";

  function paintRange(input) {
    input.style.setProperty("--fill", `${((input.value - input.min) / (input.max - input.min)) * 100}%`);
  }

  function updatePlay() {
    const s = STOCKS[active];
    const size = Number($("size").value);
    const spread = Number($("spread").value) / 10_000;
    const pool = s.close * (1 + s.premium);
    const poolAbove = s.premium > 0;
    const desk = s.close * (poolAbove ? 1 + spread : 1 - spread);

    // The trade closes part of the gap; bigger trades vs pool depth close more of it.
    const closed = size / (size + s.depth);
    const premiumAfter = s.premium * (1 - closed);
    const avgPool = s.close * (1 + (s.premium + premiumAfter) / 2);
    const edge = poolAbove ? avgPool / desk - 1 : desk / avgPool - 1;
    const worthIt = edge > 0;
    const traderProfit = worthIt ? size * edge : 0;
    const lpEarn = worthIt ? size * spread / (1 + spread) : 0;

    $("pClose").textContent = usd(s.close);
    $("pPool").textContent = usd(pool);
    $("pPrem").textContent = pct(s.premium);
    $("pPrem").classList.toggle("neg", s.premium < 0);
    $("pDeskLabel").textContent = poolAbove ? "Desk sells at" : "Desk buys at";
    $("pDesk").textContent = usd(desk);
    $("vSize").textContent = usd(size);
    $("vSpread").textContent = `${(spread * 100).toFixed(2)}%`;
    $("oTrader").textContent = usd(traderProfit);
    $("oLp").textContent = usd(lpEarn);
    $("oAfter").textContent = worthIt ? pct(premiumAfter) : pct(s.premium);

    $("verdict").textContent = !worthIt
      ? `Spread too wide. Nobody trades, the pool stays ${pct(s.premium)} off, and LPs earn nothing. The agent should tighten it.`
      : poolAbove
        ? `You buy ${active} from the desk at ${usd(desk)} and sell into the pool. The premium shrinks from ${pct(s.premium)} to ${pct(premiumAfter)}.`
        : `You buy cheap ${active} in the pool and sell it to the desk at ${usd(desk)}. The discount shrinks from ${pct(s.premium)} to ${pct(premiumAfter)}.`;
    paintRange($("size"));
    paintRange($("spread"));
  }

  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      active = tab.dataset.stock;
      document.querySelectorAll(".tab").forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      updatePlay();
    });
  });
  $("size").addEventListener("input", updatePlay);
  $("spread").addEventListener("input", updatePlay);
  updatePlay();

  // ------------------------------------------------------------ live desk status (NYSE regular hours)
  const OPEN = 9 * 3600 + 30 * 60;
  const CLOSE = 16 * 3600;
  const nyParts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", weekday: "short", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const isWeekday = (d) => d >= 1 && d <= 5;
  const fmt = (s) => [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60].map((n) => String(n).padStart(2, "0")).join(":");

  function nyNow() {
    const parts = Object.fromEntries(nyParts.formatToParts(new Date()).map((x) => [x.type, x.value]));
    return { day: DAYS.indexOf(parts.weekday), secs: +parts.hour * 3600 + +parts.minute * 60 + +parts.second };
  }

  function updateDesk() {
    const { day, secs } = nyNow();
    const marketOpen = isWeekday(day) && secs >= OPEN && secs < CLOSE;
    let wait;
    if (marketOpen) {
      wait = CLOSE - secs;
    } else {
      let days = 0;
      let d = day;
      if (!(isWeekday(d) && secs < OPEN)) {
        do { d = (d + 1) % 7; days++; } while (!isWeekday(d));
      }
      wait = days * 86400 + OPEN - secs;
    }
    $("deskState").textContent = marketOpen ? "Desk closed · NYSE is open" : "Desk open · Wall Street is asleep";
    $("deskNext").textContent = marketOpen ? "until the closing bell. Then the night shift starts." : "until the NYSE opens. The desk is quoting last close ± spread.";
    $("deskCount").textContent = fmt(wait);
    $("nyTime").textContent = fmt(secs).slice(0, 5);
    document.querySelector(".desk").classList.toggle("closed-desk", marketOpen);
  }
  updateDesk();
  setInterval(updateDesk, 1000);
})();
