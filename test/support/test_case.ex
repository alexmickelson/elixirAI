defmodule ElixirAi.TestCase do
  use ExUnit.CaseTemplate
  use Mimic

  using do
    quote do
      use Mimic
    end
  end

  setup :set_mimic_global

  setup do
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic -> [] end)
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic, _schema -> [] end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server, _messages, _tools, _provider ->
      :ok
    end)

    :ok
  end
end
