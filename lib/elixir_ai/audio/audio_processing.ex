defmodule ElixirAi.AudioProcessing do
  @moduledoc """
  Public API for the demand-driven audio transcription pool.

  Dispatch strategy:
    1. Pick a random idle worker from the :available pg group.
    2. If none are idle and the pool is below @max_workers, spawn a fresh worker
       under AudioWorkerSupervisor and route the job directly to it.
    3. If already at @max_workers, queue the job to a random existing worker via
       its Erlang mailbox — it will process it when its current job finishes.

  Scale-up is fully automatic (on demand). Scale-down is handled by each worker's
  idle-timeout logic; workers exit after idling and the pool can reach 0.
  """

  @max_workers 10
  @all_group :all
  @available_group :available

  @doc """
  Submit audio for transcription. The result is delivered asynchronously to
  `caller_pid` as:

      {:transcription_result, {:ok, text} | {:error, reason}}
  """
  def submit(audio_binary, mime_type, caller_pid) do
    case :pg.get_members(ElixirAi.AudioProcessingPG, @available_group) do
      [] ->
        all = :pg.get_members(ElixirAi.AudioProcessingPG, @all_group)

        if length(all) < @max_workers do
          {:ok, pid} =
            DynamicSupervisor.start_child(ElixirAi.AudioWorkerSupervisor, ElixirAi.AudioWorker)

          GenServer.cast(pid, {:transcribe, caller_pid, audio_binary, mime_type})
        else
          # At max capacity — overflow to a random worker's mailbox
          GenServer.cast(Enum.random(all), {:transcribe, caller_pid, audio_binary, mime_type})
        end

      available ->
        GenServer.cast(Enum.random(available), {:transcribe, caller_pid, audio_binary, mime_type})
    end

    :ok
  end
end
