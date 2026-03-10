defmodule ElixirAi.AiProvider do
  import Ecto.Query
  alias ElixirAi.Repo

  def all do
    Repo.all(
      from(p in "ai_providers",
        select: %{
          id: p.id,
          name: p.name,
          model_name: p.model_name,
          api_token: p.api_token,
          completions_url: p.completions_url
        }
      )
    )
  end

  def create(attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case Repo.insert_all("ai_providers", [
           [
             name: attrs.name,
             model_name: attrs.model_name,
             api_token: attrs.api_token,
             completions_url: attrs.completions_url,
             inserted_at: now,
             updated_at: now
           ]
         ]) do
      {1, _} ->
        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          "ai_providers",
          {:provider_added, attrs}
        )

        :ok

      _ ->
        {:error, :db_error}
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "ai_providers_name_key",
        do: {:error, :already_exists},
        else: {:error, :db_error}
  end

  def find_by_name(name) do
    case Repo.one(
           from(p in "ai_providers",
             where: p.name == ^name,
             select: %{
               id: p.id,
               name: p.name,
               model_name: p.model_name,
               api_token: p.api_token,
               completions_url: p.completions_url
             }
           )
         ) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  def ensure_default_provider do
    case Repo.aggregate(from(p in "ai_providers"), :count) do
      0 ->
        attrs = %{
          name: System.get_env("DEFAULT_PROVIDER_NAME", "default_provider"),
          model_name: System.get_env("DEFAULT_MODEL_NAME", "gpt-4"),
          api_token: System.get_env("DEFAULT_API_TOKEN", ""),
          completions_url:
            System.get_env(
              "DEFAULT_COMPLETIONS_URL",
              "https://api.openai.com/v1/chat/completions"
            )
        }

        create(attrs)

      _ ->
        :ok
    end
  end
end
