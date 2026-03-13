defmodule SQLTest do
  use ElixirAi.TestCase
  alias ElixirAi.Data.DbHelpers

  test "converts simple named parameters" do
    query = "SELECT * FROM users WHERE id = $(id) AND email = $(email)"

    params = %{
      "id" => 10,
      "email" => "test@example.com"
    }

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {
               "SELECT * FROM users WHERE id = $1 AND email = $2",
               [10, "test@example.com"]
             }
  end

  test "reuses positional parameter for repeated named parameter" do
    query = """
    SELECT * FROM users
    WHERE id = $(id)
    OR owner_id = $(id)
    """

    params = %{"id" => 42}

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {
               """
               SELECT * FROM users
               WHERE id = $1
               OR owner_id = $1
               """,
               [42]
             }
  end

  test "assigns parameters in order of first appearance" do
    query = "SELECT * FROM items WHERE category = $(category) AND owner = $(owner)"

    params = %{
      "owner" => 5,
      "category" => "books"
    }

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {
               "SELECT * FROM items WHERE category = $1 AND owner = $2",
               ["books", 5]
             }
  end

  test "handles multiple distinct parameters" do
    query = "INSERT INTO posts(title, body, author_id) VALUES($(title), $(body), $(author))"

    params = %{
      "title" => "Hello",
      "body" => "World",
      "author" => 7
    }

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {
               "INSERT INTO posts(title, body, author_id) VALUES($1, $2, $3)",
               ["Hello", "World", 7]
             }
  end

  test "works when same parameter appears many times" do
    query = """
    SELECT *
    FROM logs
    WHERE user_id = $(user)
    OR editor_id = $(user)
    OR reviewer_id = $(user)
    """

    params = %{"user" => 99}

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {
               """
               SELECT *
               FROM logs
               WHERE user_id = $1
               OR editor_id = $1
               OR reviewer_id = $1
               """,
               [99]
             }
  end

  test "raises if parameter is missing" do
    query = "SELECT * FROM users WHERE id = $(id)"

    params = %{}

    assert_raise KeyError, fn ->
      DbHelpers.named_params_to_positional_params(query, params)
    end
  end

  test "query without named parameters returns unchanged query and empty params" do
    query = "SELECT * FROM users"

    params = %{}

    assert DbHelpers.named_params_to_positional_params(query, params) ==
             {"SELECT * FROM users", []}
  end
end
