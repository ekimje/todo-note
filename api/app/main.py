"""할 일 노트 API (애플리케이션 티어).

web(nginx) -> api(FastAPI, 이 파일) -> db(PostgreSQL)
PC 설치판(desktop/)은 같은 라우터를 SQLite 로 쓴다.
"""
from contextlib import asynccontextmanager
from datetime import date, datetime, timezone
from typing import Literal, Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, FastAPI, HTTPException, Response
from pydantic import BaseModel, Field, field_validator

from . import db as dbmod
from .config import DATABASE_URL

Priority = Literal["high", "mid", "low"]

COLUMNS = "id, text, done, priority, start, due, color, created_at, updated_at"
RANGE_ERROR = "시작일은 마감일보다 늦을 수 없고, 시작일을 쓰려면 마감일이 필요해요"

db = dbmod.connect(DATABASE_URL)
router = APIRouter()


def now():
    return datetime.now(timezone.utc)


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.open()
    yield
    db.close()


# ---------- 모델 ----------
def _clean_text(v: Optional[str]) -> Optional[str]:
    if v is None:
        return v
    v = v.strip()
    if not v:
        raise ValueError("할 일 내용이 비어 있어요")
    return v


class TodoCreate(BaseModel):
    text: str = Field(max_length=200)
    priority: Priority = "mid"
    start: Optional[date] = None   # 기간 일정의 시작일 (없으면 하루 일정)
    due: Optional[date] = None     # 마감일 = 기간 일정의 종료일
    color: Optional[int] = Field(default=None, ge=0, le=4)  # 달력 형광펜 색 번호 0~4

    _v_text = field_validator("text")(_clean_text)


class TodoUpdate(BaseModel):
    text: Optional[str] = Field(default=None, max_length=200)
    done: Optional[bool] = None
    priority: Optional[Priority] = None
    start: Optional[date] = None
    due: Optional[date] = None
    color: Optional[int] = Field(default=None, ge=0, le=4)

    _v_text = field_validator("text")(_clean_text)


class Todo(BaseModel):
    id: UUID
    text: str
    done: bool
    priority: Priority
    start: Optional[date]
    due: Optional[date]
    color: Optional[int]
    created_at: datetime
    updated_at: datetime


# ---------- 라우트 ----------
@router.get("/health")
def health():
    db.run("SELECT 1")
    return {"status": "ok", "db": "ok"}


@router.get("/todos", response_model=list[Todo])
def list_todos():
    rows, _ = db.run(
        f"SELECT {COLUMNS} FROM todos "
        "ORDER BY done, due NULLS LAST, "
        "CASE priority WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, created_at"
    )
    return rows


@router.post("/todos", response_model=Todo, status_code=201)
def create_todo(body: TodoCreate):
    due = body.due or body.start  # 시작일만 주면 하루 일정
    start = body.start if body.start and body.start != due else None
    t = now()
    try:
        rows, _ = db.run(
            "INSERT INTO todos (id, text, done, priority, start, due, color, created_at, updated_at) "
            f"VALUES (%s, %s, FALSE, %s, %s, %s, %s, %s, %s) RETURNING {COLUMNS}",
            (uuid4(), body.text, body.priority, start, due, body.color, t, t),
        )
    except dbmod.ConstraintError:
        raise HTTPException(422, RANGE_ERROR)
    return rows[0]


@router.patch("/todos/{todo_id}", response_model=Todo)
def update_todo(todo_id: UUID, body: TodoUpdate):
    # exclude_unset: 보낸 필드만 수정 (due: null 을 보내면 마감일 삭제)
    patch = body.model_dump(exclude_unset=True)
    if "text" in patch and patch["text"] is None:
        raise HTTPException(422, "text 는 null 일 수 없어요")
    if any(patch.get(k) is None for k in ("done", "priority") if k in patch):
        raise HTTPException(422, "done/priority 는 null 일 수 없어요")
    if not patch:
        raise HTTPException(400, "수정할 내용이 없어요")
    sets = ", ".join(f"{k} = %s" for k in patch)  # 키는 모델 필드로만 제한됨
    try:
        rows, _ = db.run(
            f"UPDATE todos SET {sets}, updated_at = %s WHERE id = %s RETURNING {COLUMNS}",
            (*patch.values(), now(), todo_id),
        )
    except dbmod.ConstraintError:
        raise HTTPException(422, RANGE_ERROR)
    if not rows:
        raise HTTPException(404, "할 일을 찾을 수 없어요")
    return rows[0]


@router.delete("/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: UUID):
    _, count = db.run("DELETE FROM todos WHERE id = %s", (todo_id,))
    if count == 0:
        raise HTTPException(404, "할 일을 찾을 수 없어요")
    return Response(status_code=204)


@router.delete("/todos")
def clear_done():
    """완료 항목 일괄 삭제."""
    _, count = db.run("DELETE FROM todos WHERE done = TRUE")
    return {"deleted": count}


def create_app(prefix: str = "", root_path: str = "/api") -> FastAPI:
    """prefix: 라우트 앞에 붙일 경로, root_path: 프록시가 떼어 낸 경로 (문서 링크용)."""
    application = FastAPI(title="할 일 노트 API", version="1.1.0", lifespan=lifespan, root_path=root_path)
    application.include_router(router, prefix=prefix)
    return application


# Docker: nginx 가 /api 를 떼고 넘겨줌 (/api/todos -> api:8000/todos)
app = create_app()
