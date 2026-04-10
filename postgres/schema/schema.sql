CREATE TABLE IF NOT EXISTS capabilities (
  id    SERIAL PRIMARY KEY,
  name  TEXT   NOT NULL UNIQUE
);

INSERT INTO capabilities (name) VALUES ('text'), ('image'), ('voice_assistant'), ('shell_classification')
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS ai_providers (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT        NOT NULL UNIQUE,
  model_name      TEXT        NOT NULL,
  api_token       TEXT        NOT NULL,
  completions_url TEXT        NOT NULL,
  inserted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ai_provider_capabilities (
  ai_provider_id  UUID    NOT NULL REFERENCES ai_providers(id) ON DELETE CASCADE,
  capability_id   INTEGER NOT NULL REFERENCES capabilities(id) ON DELETE CASCADE,
  UNIQUE (ai_provider_id, capability_id)
);

CREATE TABLE IF NOT EXISTS conversations (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT        NOT NULL UNIQUE,
  ai_provider_id UUID        NOT NULL REFERENCES ai_providers(id) ON DELETE RESTRICT,
  category       TEXT        NOT NULL DEFAULT 'user-web',
  allowed_tools  JSONB       NOT NULL DEFAULT '[]',
  tool_choice    TEXT        NOT NULL DEFAULT 'auto' CHECK (tool_choice IN ('auto', 'none', 'required')),
  inserted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS text_messages (
  id                 BIGSERIAL   PRIMARY KEY,
  conversation_id    UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  prev_message_id    BIGINT,
  prev_message_table TEXT        CHECK (prev_message_table IN ('text_messages', 'tool_calls_request_messages', 'tool_response_messages')),
  role               TEXT        NOT NULL CHECK (role IN ('user', 'assistant')),
  content            TEXT,
  reasoning_content  TEXT,
  tool_choice        TEXT        CHECK (tool_choice IN ('auto', 'none', 'required')),
  input_tokens       INTEGER,
  output_tokens      INTEGER,
  tokens_per_second  FLOAT,
  inserted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tool_calls_request_messages (
  id                 BIGSERIAL   PRIMARY KEY,
  text_message_id    BIGINT      NOT NULL REFERENCES text_messages(id) ON DELETE CASCADE,
  prev_message_id    BIGINT,
  prev_message_table TEXT        CHECK (prev_message_table IN ('text_messages', 'tool_calls_request_messages', 'tool_response_messages')),
  tool_name          TEXT        NOT NULL,
  tool_call_id       TEXT        NOT NULL UNIQUE,
  arguments          JSONB       NOT NULL,
  approval_decision       TEXT        CHECK (approval_decision IN ('auto_allowed', 'approved', 'denied', 'timed_out')),
  approval_justification  TEXT,
  inserted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tool_response_messages (
  id                 BIGSERIAL   PRIMARY KEY,
  tool_call_id       TEXT        NOT NULL REFERENCES tool_calls_request_messages(tool_call_id) ON DELETE CASCADE,
  prev_message_id    BIGINT,
  prev_message_table TEXT        CHECK (prev_message_table IN ('text_messages', 'tool_calls_request_messages', 'tool_response_messages')),
  content            TEXT        NOT NULL,
  inserted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_text_messages_conversation   ON text_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_text_messages_prev           ON text_messages(prev_message_id);
CREATE INDEX IF NOT EXISTS idx_tool_call_msgs_prev          ON tool_calls_request_messages(prev_message_id);
CREATE INDEX IF NOT EXISTS idx_tool_call_msgs_text_msg      ON tool_calls_request_messages(text_message_id);
CREATE INDEX IF NOT EXISTS idx_tool_call_msgs_tool_call_id  ON tool_calls_request_messages(tool_call_id);
CREATE INDEX IF NOT EXISTS idx_tool_response_msgs_prev      ON tool_response_messages(prev_message_id);
CREATE INDEX IF NOT EXISTS idx_ai_provider_capabilities_provider ON ai_provider_capabilities(ai_provider_id);
