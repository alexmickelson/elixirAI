-- drop table if exists messages cascade;
-- drop table if exists conversations cascade;
-- drop table if exists ai_providers cascade;


CREATE TABLE IF NOT EXISTS ai_providers (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT        NOT NULL UNIQUE,
  model_name      TEXT        NOT NULL,
  api_token       TEXT        NOT NULL,
  completions_url TEXT        NOT NULL,
  inserted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS conversations (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT        NOT NULL UNIQUE,
  ai_provider_id UUID        NOT NULL REFERENCES ai_providers(id) ON DELETE RESTRICT,
  inserted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS messages (
  id                BIGSERIAL   PRIMARY KEY,
  conversation_id   UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role              TEXT        NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
  content           TEXT,
  reasoning_content TEXT,
  tool_calls        JSONB,
  tool_call_id      TEXT,
  inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
