// 할 일 노트 — 프레젠테이션 티어. 데이터는 /api (FastAPI → PostgreSQL) 에 저장한다.
(function () {
  "use strict";
  const API = "/api";
  const PRI_LABEL = { high: "높음", mid: "보통", low: "낮음" };
  const PRI_RANK = { high: 0, mid: 1, low: 2 };
  const POLL_MS = 15000;
  const COLORS = ["#E0B800", "#3FA34D", "#E0508E", "#3D8BE0", "#E07B1F"]; // 바탕화면 달력 위젯과 같은 색

  let todos = [];
  let filter = "all";
  let loaded = false;
  let editingId = null;
  let pending = 0; // 진행 중인 쓰기 요청 수 — 이 동안은 서버 목록으로 덮어쓰지 않음

  const $ = (id) => document.getElementById(id);
  const pad = (n) => String(n).padStart(2, "0");
  const now = new Date();
  const todayStr = now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate());
  const days = ["일", "월", "화", "수", "목", "금", "토"];
  $("today").textContent = todayStr.replace(/-/g, ".") + " (" + days[now.getDay()] + ")";

  try { const f = localStorage.getItem("todo-filter"); if (f) filter = f; } catch (e) {}

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

  function render() {
    document.querySelectorAll(".filters button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.f === filter)));
    const left = todos.filter((t) => !t.done).length;
    const doneCount = todos.length - left;
    $("summary").innerHTML = todos.length ? "남은 일 <b>" + left + "</b> / 전체 " + todos.length : "";
    $("clearDone").hidden = doneCount === 0;

    const shown = sorted(todos.filter((t) => filter === "all" || (filter === "done" ? t.done : !t.done)));
    const list = $("list");
    list.replaceChildren(...shown.map(row));
    list.hidden = shown.length === 0;

    const empty = $("empty");
    empty.hidden = shown.length > 0;
    if (!loaded) empty.innerHTML = "<strong>불러오는 중…</strong>저장된 할 일을 가져오고 있어요.";
    else if (!todos.length) empty.innerHTML = "<strong>아직 할 일이 없어요</strong>위 입력란에 첫 할 일을 적고 Enter를 누르세요.";
    else if (filter === "done") empty.innerHTML = "<strong>완료한 일이 없어요</strong>체크한 항목이 여기에 모입니다.";
    else empty.innerHTML = "<strong>모두 끝냈어요</strong>진행 중인 할 일이 없습니다.";
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
