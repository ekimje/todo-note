"""DB 연결 — PostgreSQL(Docker 배포) 과 SQLite(PC 설치판) 를 같은 인터페이스로.

DATABASE_URL 이 sqlite:///경로 이면 SQLite, 아니면 PostgreSQL.
SQL 은 %s 자리표시자로 쓰고, SQLite 에서는 ? 로 바꿔 실행한다.
"""
import sqlite3
import threading
from datetime import date, datetime
from uuid import UUID


class ConstraintError(Exception):
    """CHECK 제약 위반 (시작일 > 마감일 등)."""


PG_SCHEMA = """
CREATE TABLE IF NOT EXISTS todos (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    text        VARCHAR(200) NOT NULL CHECK (length(trim(text)) > 0),
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    priority    VARCHAR(4)   NOT NULL DEFAULT 'mid' CHECK (priority IN ('high', 'mid', 'low')),
    due         DATE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- v2: 기간 일정(start ~ due)과 달력 위젯 형광펜 색
ALTER TABLE todos ADD COLUMN IF NOT EXISTS start DATE;
ALTER TABLE todos ADD COLUMN IF NOT EXISTS color SMALLINT;
DO $$ BEGIN
    ALTER TABLE todos ADD CONSTRAINT todos_color_range CHECK (color IS NULL OR color BETWEEN 0 AND 4);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    -- 시작일은 마감일이 있을 때만, 마감일보다 늦을 수 없음
    ALTER TABLE todos ADD CONSTRAINT todos_start_before_due CHECK (start IS NULL OR (due IS NOT NULL AND start <= due));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
"""

# 날짜·시각은 ISO 문자열로 저장 (문자열 비교 = 날짜 비교)
SQLITE_SCHEMA = """
CREATE TABLE IF NOT EXISTS todos (
    id          TEXT    PRIMARY KEY,
    text        TEXT    NOT NULL CHECK (length(trim(text)) > 0 AND length(text) <= 200),
    done        INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
    priority    TEXT    NOT NULL DEFAULT 'mid' CHECK (priority IN ('high', 'mid', 'low')),
    start       TEXT,
    due         TEXT,
    color       INTEGER CHECK (color IS NULL OR color BETWEEN 0 AND 4),
    created_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL,
    CHECK (start IS NULL OR (due IS NOT NULL AND start <= due))
);
"""


class PostgresDB:
    def __init__(self, url: str):
        from psycopg.rows import dict_row
        from psycopg_pool import ConnectionPool

        self.pool = ConnectionPool(url, min_size=1, max_size=10, open=False, kwargs={"row_factory": dict_row})

    def open(self):
        self.pool.open(wait=True, timeout=30)
        self.run(PG_SCHEMA)

    def close(self):
        self.pool.close()

    def run(self, sql, params=()):
        """실행 후 (행 목록, 영향받은 행 수)."""
        from psycopg import errors

        try:
            with self.pool.connection() as conn:
                cur = conn.execute(sql, params or None)
                rows = cur.fetchall() if cur.description else []
                return rows, cur.rowcount
        except errors.CheckViolation as e:
            raise ConstraintError(str(e)) from e


def _to_sqlite(v):
    if isinstance(v, UUID):
        return str(v)
    if isinstance(v, datetime):  # 자릿수를 고정해야 문자열 정렬 = 시간 정렬
        return v.isoformat(timespec="microseconds")
    if isinstance(v, date):
        return v.isoformat()
    return v


class SQLiteDB:
    def __init__(self, path: str):
        self.path = path
        self.conn = None
        self.lock = threading.Lock()  # 라우트가 스레드풀에서 돌므로 연결 하나를 잠가서 공유

    def open(self):
        self.conn = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SQLITE_SCHEMA)

    def close(self):
        if self.conn:
            self.conn.close()

    def run(self, sql, params=()):
        sql = sql.replace("%s", "?")
        params = tuple(_to_sqlite(p) for p in params)
        with self.lock:
            try:
                cur = self.conn.execute(sql, params)
                rows = [dict(r) for r in cur.fetchall()]
                return rows, cur.rowcount
            except sqlite3.IntegrityError as e:
                if "CHECK" in str(e):
                    raise ConstraintError(str(e)) from e
                raise


def connect(url: str):
    if url.startswith("sqlite:///"):
        return SQLiteDB(url[len("sqlite:///"):])
    return PostgresDB(url)
