import os

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://{user}:{pw}@{host}:{port}/{db}".format(
        user=os.environ.get("POSTGRES_USER", "todo"),
        pw=os.environ.get("POSTGRES_PASSWORD", ""),
        host=os.environ.get("POSTGRES_HOST", "db"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        db=os.environ.get("POSTGRES_DB", "todo"),
    ),
)
