"""할 일 노트 API (애플리케이션 티어).

web(nginx) -> api(FastAPI, 이 파일) -> db(PostgreSQL)
"""
from contextlib import asynccontextmanager
from datetime import date, datetime
from typing import Literal, Optional
from uuid import UUID

from fastapi import FastAPI, HTTPException, Response
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field, field_validator

from .config import DATABASE_URL

Priority = Literal["high", "mid", "low"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS todos (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    text        VARCHAR(200) NOT NULL CHECK (length(trim(text)) > 0),
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    priority    VARCHAR(4)   NOT NULL DEFAULT 'mid' CHECK (priority IN ('high', 'mid', 'low')),
    due         DATE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
"""

COLUMNS = "id, text, done, priority, due, created_at, updated_at"

pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=10, open=False, kwargs={"row_factory": dict_row})


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True, timeout=30)
    with pool.connection() as conn:
        conn.execute(SCHEMA)
    yield
    pool.close()


app = FastAPI(title="할 일 노트 API", version="1.0.0", lifespan=lifespan, root_path="/api")


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
    due: Optional[date] = None

    _v_text = field_validator("text")(_clean_text)


class TodoUpdate(BaseModel):
    text: Optional[str] = Field(default=None, max_length=200)
    done: Optional[bool] = None
    priority: Optional[Priority] = None
    due: Optional[date] = None

    _v_text = field_validator("text")(_clean_text)


class Todo(BaseModel):
    id: UUID
    text: str
    done: bool
    priority: Priority
    due: Optional[date]
    created_at: datetime
    updated_at: datetime


# ---------- 라우트 ----------
@app.get("/health")
def health():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok", "db": "ok"}


@app.get("/todos", response_model=list[Todo])
def list_todos():
    with pool.connection() as conn:
        return conn.execute(
            f"SELECT {COLUMNS} FROM todos "
            "ORDER BY done, due NULLS LAST, "
            "CASE priority WHEN 'high' THEN 0 WHEN 'mid' THEN 1 ELSE 2 END, created_at"
        ).fetchall()


@app.post("/todos", response_model=Todo, status_code=201)
def create_todo(body: TodoCreate):
    with pool.connection() as conn:
        return conn.execute(
            f"INSERT INTO todos (text, priority, due) VALUES (%s, %s, %s) RETURNING {COLUMNS}",
            (body.text, body.priority, body.due),
        ).fetchone()


@app.patch("/todos/{todo_id}", response_model=Todo)
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
    with pool.connection() as conn:
        row = conn.execute(
            f"UPDATE todos SET {sets}, updated_at = now() WHERE id = %s RETURNING {COLUMNS}",
            (*patch.values(), todo_id),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "할 일을 찾을 수 없어요")
    return row


@app.delete("/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: UUID):
    with pool.connection() as conn:
        cur = conn.execute("DELETE FROM todos WHERE id = %s", (todo_id,))
    if cur.rowcount == 0:
        raise HTTPException(404, "할 일을 찾을 수 없어요")
    return Response(status_code=204)


@app.delete("/todos")
def clear_done():
    """완료 항목 일괄 삭제."""
    with pool.connection() as conn:
        cur = conn.execute("DELETE FROM todos WHERE done = TRUE")
    return {"deleted": cur.rowcount}
