defmodule ElixirAi.Data.AiProviderSchema do
  defstruct [:id, :name, :model_name, :api_token, :completions_url, :inserted_at, :updated_at]

  def schema do
    Zoi.object(%{
      id: Zoi.string(),
      name: Zoi.string(),
      model_name: Zoi.string(),
      api_token: Zoi.string(),
      completions_url: Zoi.string()
    })
  end

  def partial_schema do
    Zoi.object(%{
      id: Zoi.string(),
      name: Zoi.string(),
      model_name: Zoi.string()
    })
  end
end
