defmodule ElixirAi.Conversation do
  import Ecto.Query
  alias ElixirAi.Repo

  def all_names do
    Repo.all(
      from(c in "conversations",
        left_join: p in "ai_providers",
        on: c.ai_provider_id == p.id,
        select: %{
          name: c.name,
          provider: %{
            name: p.name,
            model_name: p.model_name,
            api_token: p.api_token,
            completions_url: p.completions_url
          }
        }
      )
    )
  end

  def create(name, ai_provider_id) do
    case Repo.insert_all("conversations", [
           [name: name, ai_provider_id: ai_provider_id, inserted_at: now(), updated_at: now()]
         ]) do
      {1, _} -> :ok
      _ -> {:error, :db_error}
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "conversations_name_index",
        do: {:error, :already_exists},
        else: {:error, :db_error}
  end

  def find_id(name) do
    case Repo.one(from(c in "conversations", where: c.name == ^name, select: c.id)) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
