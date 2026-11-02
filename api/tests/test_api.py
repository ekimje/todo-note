"""실행 중인 스택(web → api → db)에 대한 통합 테스트.

    docker compose up -d --build
    python -m pytest api/tests -v            # 기본 대상: http://localhost:8080/api
    TODO_API_URL=http://<vm>:8080/api python -m pytest api/tests

테스트가 만든 할 일만 지우므로 기존 데이터는 건드리지 않는다.
"""
import json
import os
import urllib.error
import urllib.request
import uuid

import pytest

BASE = os.environ.get("TODO_API_URL", "http://localhost:8080/api").rstrip("/")


def call(method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            raw = res.read()
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, json.loads(raw) if raw else None


@pytest.fixture
def made():
    """테스트 중 만든 id 를 모아 두었다가 끝나면 삭제."""
    ids = []
    yield ids
    for i in ids:
        call("DELETE", f"/todos/{i}")


def create(made, **body):
    status, todo = call("POST", "/todos", body)
    assert status == 201, todo
    made.append(todo["id"])
    return todo


# ---------- 기본 ----------
def test_health():
    assert call("GET", "/health") == (200, {"status": "ok", "db": "ok"})


def test_create_defaults_and_korean(made):
    t = create(made, text="  한글 할 일 ✓  ")
    assert t["text"] == "한글 할 일 ✓"          # 앞뒤 공백 제거
    assert t["done"] is False and t["priority"] == "mid"
    assert t["start"] is None and t["due"] is None and t["color"] is None
    _, items = call("GET", "/todos")
    assert any(x["id"] == t["id"] and x["text"] == "한글 할 일 ✓" for x in items)


def test_patch_only_sent_fields(made):
    t = create(made, text="원래", priority="high", due="2026-11-05")
    s, p = call("PATCH", f"/todos/{t['id']}", {"done": True})
    assert s == 200 and p["done"] is True and p["text"] == "원래" and p["due"] == "2026-11-05"
    s, p = call("PATCH", f"/todos/{t['id']}", {"due": None})
    assert s == 200 and p["due"] is None


def test_delete_and_404(made):
    t = create(made, text="지울 것")
    assert call("DELETE", f"/todos/{t['id']}")[0] == 204
    assert call("DELETE", f"/todos/{t['id']}")[0] == 404
    assert call("PATCH", f"/todos/{uuid.uuid4()}", {"done": True})[0] == 404


def test_clear_done_only_removes_done(made):
    if any(x["done"] for x in call("GET", "/todos")[1]):
        pytest.skip("실제 완료 항목이 있어 일괄 삭제 테스트를 건너뜀 (사용자 데이터 보호)")
    a = create(made, text="완료됨")
    b = create(made, text="진행 중")
    call("PATCH", f"/todos/{a['id']}", {"done": True})
    s, r = call("DELETE", "/todos")
    assert s == 200 and r["deleted"] >= 1
    ids = {x["id"] for x in call("GET", "/todos")[1]}
    assert a["id"] not in ids and b["id"] in ids


# ---------- 기간 일정 / 색 (달력 위젯 연동) ----------
def test_range_event(made):
    t = create(made, text="개인 프로젝트", start="2026-10-30", due="2026-11-02", color=3)
    assert (t["start"], t["due"], t["color"]) == ("2026-10-30", "2026-11-02", 3)


def test_start_only_becomes_single_day(made):
    t = create(made, text="하루", start="2026-11-10")
    assert t["start"] is None and t["due"] == "2026-11-10"


def test_same_start_and_due_is_single_day(made):
    t = create(made, text="하루2", start="2026-11-10", due="2026-11-10")
    assert t["start"] is None and t["due"] == "2026-11-10"


def test_start_after_due_rejected(made):
    s, r = call("POST", "/todos", {"text": "거꾸로", "start": "2026-11-05", "due": "2026-11-01"})
    assert s == 422 and "시작일" in r["detail"]


def test_patch_cannot_break_range(made):
    t = create(made, text="기간", start="2026-11-01", due="2026-11-03")
    assert call("PATCH", f"/todos/{t['id']}", {"due": None})[0] == 422          # 시작일만 남는 상태 금지
    assert call("PATCH", f"/todos/{t['id']}", {"start": "2026-11-09"})[0] == 422  # 시작 > 마감 금지
    s, p = call("PATCH", f"/todos/{t['id']}", {"start": None, "due": None})       # 둘 다 지우는 건 허용
    assert s == 200 and p["start"] is None and p["due"] is None


# ---------- 입력 검증 ----------
@pytest.mark.parametrize("body", [
    {"text": "   "},
    {"text": ""},
    {"text": "x" * 201},
    {"text": "x", "priority": "urgent"},
    {"text": "x", "color": 5},
    {"text": "x", "color": -1},
    {"text": "x", "due": "2026-13-01"},
    {},
])
def test_invalid_create_rejected(body):
    assert call("POST", "/todos", body)[0] == 422


def test_invalid_patch_rejected(made):
    t = create(made, text="검증")
    assert call("PATCH", f"/todos/{t['id']}", {})[0] == 400
    assert call("PATCH", f"/todos/{t['id']}", {"text": None})[0] == 422
    assert call("PATCH", f"/todos/{t['id']}", {"done": None})[0] == 422
    assert call("PATCH", "/todos/not-a-uuid", {"done": True})[0] == 422
