defmodule ElixirAi.AiProvider do
  import Ecto.Query
  alias ElixirAi.Repo
  alias ElixirAi.Data.AiProviderSchema
  require Logger

  def all do
    results =
      Repo.all(
        from(p in AiProviderSchema,
          select: %{
            id: p.id,
            name: p.name,
            model_name: p.model_name
          }
        )
      )
      |> Enum.map(&convert_id_to_string/1)

    Logger.debug("AiProvider.all() returning: #{inspect(results)}")

    results
  end

  # Convert binary UUID to string for frontend
  defp convert_id_to_string(%{id: id} = provider) when is_binary(id) do
    %{provider | id: Ecto.UUID.cast!(id)}
  end

  defp convert_id_to_string(provider), do: provider

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
      provider -> {:ok, convert_id_to_string(provider)}
    end
  end

  def ensure_default_provider do
    case Repo.aggregate(from(p in "ai_providers"), :count) do
      0 ->
        attrs = %{
          name: "default",
          model_name: Application.fetch_env!(:elixir_ai, :ai_model),
          api_token: Application.fetch_env!(:elixir_ai, :ai_token),
          completions_url: Application.fetch_env!(:elixir_ai, :ai_endpoint)
        }

        create(attrs)

      _ ->
        :ok
    end
  end
end
