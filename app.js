// 할 일 노트 — 프레젠테이션 티어. 데이터는 /api (FastAPI → PostgreSQL / PC 설치판은 SQLite) 에 저장한다.
(function () {
  "use strict";
  const API = "/api";
  const PRI_LABEL = { high: "높음", mid: "보통", low: "낮음" };
  const PRI_RANK = { high: 0, mid: 1, low: 2 };
  const POLL_MS = 15000;
  const COLORS = ["#E0B800", "#3FA34D", "#E0508E", "#3D8BE0", "#E07B1F"]; // 바탕화면 달력 위젯과 같은 색
  const PRI_COLOR = { high: 2, mid: 3, low: 1 }; // 색을 고르지 않은 일정: 위젯과 같은 규칙
  const MAX_LANES = 3;                           // 달력 한 주에 쌓는 일정 줄 수 (넘치면 +n)

  let todos = [];
  let filter = "all";
  let loaded = false;
  let editingId = null;
  let pending = 0; // 진행 중인 쓰기 요청 수 — 이 동안은 서버 목록으로 덮어쓰지 않음
  let view = "list"; // list | cal

  const $ = (id) => document.getElementById(id);
  const pad = (n) => String(n).padStart(2, "0");
  const now = new Date();
  const todayStr = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate());
  const days = ["일", "월", "화", "수", "목", "금", "토"];
  $("today").textContent = todayStr.replace(/-/g, ".") + " (" + days[now.getDay()] + ")";

  let sel = todayStr;                                   // 달력에서 고른 날짜
  let calY = now.getFullYear(), calM = now.getMonth(); // 달력에 보이는 달 (월은 0부터)

  try { const f = localStorage.getItem("todo-filter"); if (f) filter = f; } catch (e) {}
  try { const v = localStorage.getItem("todo-view"); if (v === "list" || v === "cal") view = v; } catch (e) {}

  // ---------- API ----------
  async function api(method, path, body) {
    const res = await fetch(API + path, {
      method,
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) {
      let detail = "";
      try { detail = (await res.json()).detail; } catch (e) {}
      const err = new Error(typeof detail === "string" ? detail : "HTTP " + res.status);
      err.status = res.status;
      throw err;
    }
    return res.status === 204 ? null : res.json();
  }

  async function write(fn, what) {
    pending++;
    try { await fn(); showNotice(""); setSync("ok", "서버에 저장됨"); }
    catch (e) {
      showNotice(what + " 저장하지 못했어요. (" + e.message + ")");
      setSync("err", "저장 실패");
    }
    finally { pending--; if (!pending) refresh(); }
  }

  async function refresh() {
    if (pending) return;
    try {
      const data = await api("GET", "/todos");
      if (pending) return;
      todos = data;
      loaded = true;
      setSync("ok", "서버에 저장됨");
      if (!editingId) render();
    } catch (e) {
      setSync("err", "서버 연결 안 됨");
      if (!loaded) { loaded = true; render(); showNotice("서버에 연결할 수 없어요. 잠시 후 다시 시도해 주세요."); }
    }
  }

  // ---------- 화면 ----------
  function setSync(cls, text) { const s = $("sync"); s.className = "sync " + cls; s.textContent = text; }
  function showNotice(msg) { const n = $("notice"); n.textContent = msg; n.hidden = !msg; }

  function fmtDue(d) {
    if (!d) return "";
    if (d === todayStr) return "오늘";
    const [, m, day] = d.split("-");
    return Number(m) + "/" + Number(day);
  }

  function sorted(arr) {
    return arr.slice().sort((a, b) => {
      if (!!a.done !== !!b.done) return a.done ? 1 : -1;
      const da = a.due || "9999", dbb = b.due || "9999";
      if (da !== dbb) return da < dbb ? -1 : 1;
      const pa = PRI_RANK[a.priority] ?? 1, pb = PRI_RANK[b.priority] ?? 1;
      if (pa !== pb) return pa - pb;
      return String(a.created_at).localeCompare(String(b.created_at));
    });
  }

  const passes = (t) => filter === "all" || (filter === "done" ? t.done : !t.done);

  function render() {
    document.querySelectorAll(".filters button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.f === filter)));
    document.querySelectorAll(".views button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === view)));
    const isCal = view === "cal";
    $("cal").hidden = !isCal;
    $("dayHead").hidden = !isCal;
    if (isCal) renderCal();
    const left = todos.filter((t) => !t.done).length;
    const doneCount = todos.length - left;
    $("summary").innerHTML = todos.length ? "남은 일 <b>" + left + "</b> / 전체 " + todos.length : "";
    $("clearDone").hidden = doneCount === 0;

    const base = todos.filter(passes);
    const shown = sorted(isCal ? base.filter((t) => onDay(t, sel)) : base);
    const list = $("list");
    list.replaceChildren(...shown.map(row));
    list.hidden = shown.length === 0;

    const empty = $("empty");
    empty.hidden = shown.length > 0;
    if (!loaded) empty.innerHTML = "<strong>불러오는 중…</strong>저장된 할 일을 가져오고 있어요.";
    else if (isCal) empty.innerHTML = "<strong>이 날은 할 일이 없어요</strong>‘이 날짜로 추가’를 누르면 바로 적을 수 있어요.";
    else if (!todos.length) empty.innerHTML = "<strong>아직 할 일이 없어요</strong>위 입력란에 첫 할 일을 적고 Enter를 누르세요.";
    else if (filter === "done") empty.innerHTML = "<strong>완료한 일이 없어요</strong>체크한 항목이 여기에 모입니다.";
    else empty.innerHTML = "<strong>모두 끝냈어요</strong>진행 중인 할 일이 없습니다.";
  }

  // ---------- 달력 ----------
  const parse = (ds) => { const [y, m, d] = ds.split("-").map(Number); return new Date(y, m - 1, d); };
  const ymd = (d) => d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
  const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
  const startOf = (t) => t.start || t.due;
  const onDay = (t, ds) => !!t.due && startOf(t) <= ds && ds <= t.due;
  const colorOf = (t) => (t.color != null && COLORS[t.color] ? t.color : PRI_COLOR[t.priority] ?? 3);
  const dayLabel = (ds) => { const d = parse(ds); return (d.getMonth() + 1) + "월 " + d.getDate() + "일 (" + days[d.getDay()] + ")"; };

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function renderCal() {
    const first = new Date(calY, calM, 1);
    const gridStart = addDays(first, -first.getDay());
    const weekCount = Math.ceil((first.getDay() + new Date(calY, calM + 1, 0).getDate()) / 7);
    $("calTitle").textContent = calY + "년 " + (calM + 1) + "월";
    const items = todos.filter((t) => t.due && passes(t));
    const weeks = [];

    for (let w = 0; w < weekCount; w++) {
      const ws = addDays(gridStart, 7 * w);
      const wsS = ymd(ws), weS = ymd(addDays(ws, 6));
      const week = el("div", "cal-week");
      const col = (ds) => Math.round((parse(ds) - ws) / 864e5);

      for (let d = 0; d < 7; d++) {
        const date = addDays(ws, d), ds = ymd(date);
        const n = items.filter((t) => onDay(t, ds)).length;
        const cell = el("button", "cal-day");
        cell.type = "button";
        if (date.getMonth() !== calM) cell.classList.add("out");
        if (d === 0) cell.classList.add("sun");
        if (d === 6) cell.classList.add("sat");
        if (ds === todayStr) cell.classList.add("today");
        cell.style.gridColumn = String(d + 1);
        cell.setAttribute("aria-pressed", String(ds === sel));
        cell.setAttribute("aria-label", dayLabel(ds) + (n ? ", 할 일 " + n + "개" : ""));
        cell.appendChild(el("span", "num", String(date.getDate())));
        cell.addEventListener("click", () => {
          sel = ds;
          if (date.getMonth() !== calM) { calY = date.getFullYear(); calM = date.getMonth(); }
          render();
        });
        week.appendChild(cell);
      }

      // 이번 주에 걸친 일정: 먼저 시작하고 긴 것부터 빈 줄에 배치 (위젯과 같은 방식)
      const evs = items.filter((t) => startOf(t) <= weS && t.due >= wsS).sort((a, b) =>
        startOf(a) < startOf(b) ? -1 : startOf(a) > startOf(b) ? 1 :
        (parse(b.due) - parse(startOf(b))) - (parse(a.due) - parse(startOf(a))));
      const used = Array.from({ length: MAX_LANES }, () => new Array(7).fill(false));
      const hidden = new Array(7).fill(0);

      for (const t of evs) {
        const c0 = Math.max(0, col(startOf(t))), c1 = Math.min(6, col(t.due));
        let lane = -1;
        for (let l = 0; l < MAX_LANES && lane < 0; l++) {
          if (used[l].slice(c0, c1 + 1).every((x) => !x)) lane = l;
        }
        if (lane < 0) { for (let c = c0; c <= c1; c++) hidden[c]++; continue; }
        for (let c = c0; c <= c1; c++) used[lane][c] = true;

        const multi = t.due > startOf(t);
        const bar = el("div", "cal-bar c" + colorOf(t) + (multi ? " multi" : " single") + (t.done ? " done" : ""), t.text);
        if (multi && startOf(t) < wsS) bar.classList.add("cont-l");
        if (multi && t.due > weS) bar.classList.add("cont-r");
        bar.style.gridColumn = (c0 + 1) + " / " + (c1 + 2);
        bar.style.gridRow = String(lane + 2);
        bar.title = t.text + "\n" + (multi ? fmtDue(startOf(t)) + " ~ " + fmtDue(t.due) : fmtDue(t.due)) + (t.done ? " (완료)" : "");
        week.appendChild(bar);
      }
      for (let c = 0; c < 7; c++) {
        if (!hidden[c]) continue;
        const more = el("div", "cal-more", "+" + hidden[c]);
        more.style.gridColumn = String(c + 1);
        more.style.gridRow = String(MAX_LANES + 2);
        week.appendChild(more);
      }
      weeks.push(week);
    }
    $("calWeeks").replaceChildren(...weeks);

    const undated = todos.filter((t) => !t.due && passes(t)).length;
    $("calFoot").hidden = !undated;
    $("calFoot").textContent = "마감일 없는 할 일 " + undated + "개는 달력에 없고 목록에서 볼 수 있어요.";

    const n = todos.filter((t) => onDay(t, sel) && passes(t)).length;
    $("dayLabel").replaceChildren(el("b", null, dayLabel(sel)), document.createTextNode(n ? " · " + n + "개" : ""));
  }

  function showMonth(y, m) {
    calY = y + Math.floor(m / 12); calM = ((m % 12) + 12) % 12;
    const today = parse(todayStr);
    sel = today.getFullYear() === calY && today.getMonth() === calM ? todayStr : ymd(new Date(calY, calM, 1));
    render();
  }

  function row(t) {
    const li = document.createElement("li");
    li.className = "item" + (t.done ? " done" : "");
    const cb = document.createElement("input");
    cb.type = "checkbox"; cb.className = "check"; cb.checked = !!t.done;
    cb.setAttribute("aria-label", t.text + " 완료");
    cb.addEventListener("change", () => update(t.id, { done: cb.checked }));

    const body = document.createElement("div");
    body.className = "body";
    if (editingId === t.id) {
      const inp = document.createElement("input");
      inp.className = "edit-input"; inp.value = t.text; inp.maxLength = 200;
      inp.setAttribute("enterkeyhint", "done");
      const finish = (commit) => {
        if (editingId !== t.id) return;
        editingId = null;
        const v = inp.value.trim();
        if (commit && v && v !== t.text) update(t.id, { text: v }); else render();
      };
      inp.addEventListener("keydown", (e) => { if (e.key === "Enter") finish(true); if (e.key === "Escape") finish(false); });
      inp.addEventListener("blur", () => finish(true));
      body.appendChild(inp);
      setTimeout(() => inp.focus(), 0);
    } else {
      const text = document.createElement("span");
      text.className = "text"; text.textContent = t.text; text.title = "눌러서 수정";
      text.setAttribute("role", "button"); text.tabIndex = 0;
      const startEdit = () => { editingId = t.id; render(); };
      text.addEventListener("click", startEdit);
      text.addEventListener("keydown", (e) => { if (e.key === "Enter") startEdit(); });
      body.appendChild(text);
    }

    const meta = document.createElement("div");
    meta.className = "meta";
    const pri = document.createElement("span");
    pri.className = "pri " + (t.priority || "mid"); pri.textContent = PRI_LABEL[t.priority] || "보통";
    meta.appendChild(pri);
    if (t.due) {
      const late = !t.done && t.due < todayStr;
      const due = document.createElement("span");
      due.className = "due" + (late ? " late" : "");
      due.textContent = (t.start ? "기간 " + fmtDue(t.start) + " ~ " + fmtDue(t.due) : "마감 " + fmtDue(t.due)) + (late ? " · 지남" : "");
      meta.appendChild(due);
    }
    if (t.color != null && COLORS[t.color]) {
      const dot = document.createElement("span");
      dot.className = "color-dot"; dot.style.background = COLORS[t.color]; dot.title = "달력 색";
      meta.appendChild(dot);
    }
    body.appendChild(meta);

    const del = document.createElement("button");
    del.type = "button"; del.className = "del"; del.textContent = "×"; del.setAttribute("aria-label", t.text + " 삭제");
    del.addEventListener("click", () => remove(t.id));

    li.append(cb, body, del);
    return li;
  }

  // ---------- 동작 (낙관적 업데이트 후 서버 반영) ----------
  const isTemp = (id) => String(id).startsWith("tmp-"); // 아직 서버에 생성 중인 항목

  function update(id, patch) {
    if (isTemp(id)) return;
    const t = todos.find((x) => x.id === id);
    if (t) Object.assign(t, patch);
    render();
    write(() => api("PATCH", "/todos/" + id, patch), "변경 내용을");
  }

  function remove(id) {
    if (isTemp(id)) return;
    todos = todos.filter((x) => x.id !== id);
    render();
    write(() => api("DELETE", "/todos/" + id), "삭제를");
  }

  $("addForm").addEventListener("submit", (e) => {
    e.preventDefault();
    const text = $("newText").value.trim();
    if (!text) return;
    let start = $("newStart").value || null, due = $("newDue").value || null;
    if (start && !due) due = start;                       // 시작일만 → 하루 일정
    if (start && due && start > due) [start, due] = [due, start];
    if (start === due) start = null;
    const item = { text, priority: $("newPri").value, start, due };
    $("newText").value = ""; $("newStart").value = ""; $("newDue").value = ""; $("newPri").value = "mid";
    if (filter === "done") filter = "all";
    const tempId = "tmp-" + Date.now();
    todos.push(Object.assign({ id: tempId, done: false, created_at: new Date().toISOString() }, item));
    render();
    write(async () => {
      const created = await api("POST", "/todos", item);
      todos = todos.map((x) => (x.id === tempId ? created : x));
    }, "새 할 일을");
  });

  document.querySelectorAll(".filters button").forEach((b) => b.addEventListener("click", () => {
    filter = b.dataset.f;
    try { localStorage.setItem("todo-filter", filter); } catch (e) {}
    render();
  }));

  document.querySelectorAll(".views button").forEach((b) => b.addEventListener("click", () => {
    view = b.dataset.v;
    try { localStorage.setItem("todo-view", view); } catch (e) {}
    render();
  }));
  $("calPrev").addEventListener("click", () => showMonth(calY, calM - 1));
  $("calNext").addEventListener("click", () => showMonth(calY, calM + 1));
  $("calToday").addEventListener("click", () => showMonth(now.getFullYear(), now.getMonth()));
  $("dayAdd").addEventListener("click", () => {
    $("newDue").value = sel; $("newStart").value = "";
    $("newText").focus();
    $("addForm").scrollIntoView({ block: "nearest", behavior: "smooth" });
  });

  let armTimer = null;
  $("clearDone").addEventListener("click", () => {
    const btn = $("clearDone");
    if (!btn.classList.contains("armed")) {
      btn.classList.add("armed"); btn.textContent = "한 번 더 누르면 삭제";
      clearTimeout(armTimer);
      armTimer = setTimeout(() => { btn.classList.remove("armed"); btn.textContent = "완료 항목 지우기"; }, 3000);
      return;
    }
    clearTimeout(armTimer);
    btn.classList.remove("armed"); btn.textContent = "완료 항목 지우기";
    todos = todos.filter((t) => !t.done);
    render();
    write(() => api("DELETE", "/todos"), "완료 항목 삭제를");
  });

  // 다른 기기에서 바꾼 내용 반영: 주기적 새로고침 + 화면으로 돌아올 때
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  window.addEventListener("focus", refresh);

  render();
  refresh();
})();
