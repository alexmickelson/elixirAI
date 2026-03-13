defmodule ElixirAi.StreamChunkHelpers do
  @moduledoc """
  Helper functions for creating SSE-formatted AI streaming response chunks for testing.
  """

  @doc """
  Creates a response start chunk with assistant role.
  """
  def start_response(id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [
        %{
          "finish_reason" => nil,
          "index" => 0,
          "delta" => %{"role" => "assistant", "content" => nil}
        }
      ],
      "created" => 1_773_426_536,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a reasoning content chunk.
  """
  def reasoning_chunk(content, id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [
        %{"finish_reason" => nil, "index" => 0, "delta" => %{"reasoning_content" => content}}
      ],
      "created" => 1_773_426_536,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a text content chunk.
  """
  def text_chunk(content, id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [%{"finish_reason" => nil, "index" => 0, "delta" => %{"content" => content}}],
      "created" => 1_773_426_537,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a stop/finish chunk.
  """
  def stop_chunk(id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [%{"finish_reason" => "stop", "index" => 0, "delta" => %{}}],
      "created" => 1_773_426_537,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a tool call start chunk.
  """
  def tool_call_start_chunk(
        tool_name,
        arguments,
        index \\ 0,
        tool_call_id,
        id \\ "chatcmpl-test"
      ) do
    chunk = %{
      "choices" => [
        %{
          "finish_reason" => nil,
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "id" => tool_call_id,
                "index" => index,
                "type" => "function",
                "function" => %{"name" => tool_name, "arguments" => arguments}
              }
            ]
          }
        }
      ],
      "created" => 1_773_426_537,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a tool call middle chunk (continuing arguments).
  """
  def tool_call_middle_chunk(arguments, index \\ 0, id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [
        %{
          "finish_reason" => nil,
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{"index" => index, "function" => %{"arguments" => arguments}}
            ]
          }
        }
      ],
      "created" => 1_773_426_537,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates a tool call end chunk.
  """
  def tool_call_end_chunk(id \\ "chatcmpl-test") do
    chunk = %{
      "choices" => [%{"finish_reason" => "tool_calls", "index" => 0, "delta" => %{}}],
      "created" => 1_773_426_537,
      "id" => id,
      "model" => "gpt-oss-120b-F16.gguf",
      "object" => "chat.completion.chunk"
    }

    "data: #{Jason.encode!(chunk)}"
  end

  @doc """
  Creates an error chunk.
  """
  def error_chunk(message, type \\ "invalid_request_error") do
    chunk = %{"error" => %{"message" => message, "type" => type}}
    "data: #{Jason.encode!(chunk)}"
  end
end
