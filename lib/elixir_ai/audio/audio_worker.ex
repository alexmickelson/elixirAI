defmodule ElixirAi.AudioWorker do
  @moduledoc """
  GenServer that transcribes audio by posting to a Whisper-compatible HTTP endpoint.

  Pool membership in AudioProcessingPG:
    - :all       — joined on init; left only on exit
    - :available — joined on init and after each job; left while processing

  This join/leave pattern lets the AudioProcessing dispatcher know which workers are
  idle without any central coordinator. When a worker finishes a job it rejoins
  :available and becomes eligible for the next dispatch.

  Scale-down: workers exit after @idle_timeout_ms of inactivity, allowing the pool
  to reach 0. New workers are spawned on demand when the next job arrives.

  Results are delivered to the calling LiveView process as:
    {:transcription_result, {:ok, text} | {:error, reason}}
  """

  use GenServer
  require Logger

  @all_group :all
  @available_group :available
  @idle_timeout_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    :pg.join(ElixirAi.AudioProcessingPG, @all_group, self())
    :pg.join(ElixirAi.AudioProcessingPG, @available_group, self())
    schedule_idle_check()
    {:ok, %{busy: false, idle_since: monotonic_sec()}}
  end

  @impl true
  def handle_cast({:transcribe, caller_pid, audio_binary, mime_type}, state) do
    :pg.leave(ElixirAi.AudioProcessingPG, @available_group, self())
    worker = self()

    Task.start(fn ->
      result = do_transcribe(audio_binary, mime_type)
      send(worker, {:transcription_done, caller_pid, result})
    end)

    {:noreply, %{state | busy: true}}
  end

  @impl true
  def handle_info({:transcription_done, caller_pid, result}, state) do
    send(caller_pid, {:transcription_result, result})
    :pg.join(ElixirAi.AudioProcessingPG, @available_group, self())
    {:noreply, %{state | busy: false, idle_since: monotonic_sec()}}
  end

  def handle_info(:idle_check, %{busy: true} = state) do
    schedule_idle_check()
    {:noreply, state}
  end

  def handle_info(:idle_check, %{busy: false, idle_since: idle_since} = state) do
    idle_ms = (monotonic_sec() - idle_since) * 1000

    if idle_ms >= @idle_timeout_ms do
      Logger.debug("AudioWorker #{inspect(self())} exiting — idle for #{div(idle_ms, 1000)}s")

      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout_ms)
  end

  defp monotonic_sec, do: System.monotonic_time(:second)

  defp filename_for(mime_type) do
    cond do
      String.starts_with?(mime_type, "audio/webm") -> "audio.webm"
      String.starts_with?(mime_type, "audio/ogg") -> "audio.ogg"
      String.starts_with?(mime_type, "audio/mp4") -> "audio.mp4"
      true -> "audio.bin"
    end
  end

  defp do_transcribe(audio_binary, mime_type) do
    filename = filename_for(mime_type)

    {endpoint, api_token} =
      case ElixirAi.AiProvider.find_by_capability("audio") do
        {:ok, provider} -> {provider.completions_url, provider.api_token}
        _ -> {Application.get_env(:elixir_ai, :whisper_endpoint), nil}
      end

    auth_headers = if api_token, do: [authorization: "Bearer #{api_token}"], else: []

    case Req.post(endpoint,
           form_multipart: [
             file: {audio_binary, filename: filename, content_type: mime_type},
             response_format: "json",
             language: "en"
           ],
           headers: auth_headers,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"text" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("AudioWorker: Whisper returned HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("AudioWorker: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
