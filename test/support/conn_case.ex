defmodule ElixirAiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ElixirAiWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate
  use Mimic

  using do
    quote do
      # The default endpoint for testing
      @endpoint ElixirAiWeb.Endpoint

      use ElixirAiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import ElixirAiWeb.ConnCase
      use Mimic
    end
  end

  setup :set_mimic_global

  setup _tags do
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic -> [] end)
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic, _schema -> [] end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server, _messages, _tools, _provider ->
      :ok
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
