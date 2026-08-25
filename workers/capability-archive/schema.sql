CREATE TABLE IF NOT EXISTS entries (
  id         INTEGER PRIMARY KEY,
  created_at TEXT NOT NULL,
  title      TEXT NOT NULL,
  body       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at DESC);
