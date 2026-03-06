CREATE TABLE conversations (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL UNIQUE,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE messages (
  id                BIGSERIAL   PRIMARY KEY,
  conversation_id   UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role              TEXT        NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
  content           TEXT,
  reasoning_content TEXT,
  tool_calls        JSONB,
  tool_call_id      TEXT,
  inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
