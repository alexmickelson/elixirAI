defmodule ElixirAi.AiUtils.StreamLineUtilsTest do
  use ExUnit.Case
  import ElixirAi.StreamChunkHelpers
  alias ElixirAi.AiUtils.StreamLineUtils

  setup do
    test_pid = self()
    {:ok, server: test_pid}
  end

  describe "Basic handling" do
    test "handles empty string", %{server: server} do
      assert :ok = StreamLineUtils.handle_stream_line(server, "")
      refute_received _
    end

    test "handles [DONE] marker", %{server: server} do
      assert :ok = StreamLineUtils.handle_stream_line(server, "data: [DONE]")
      refute_received _
    end

    test "handles first streamed response with assistant role", %{server: server} do
      line = start_response("chatcmpl-test")

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:start_new_ai_response, "chatcmpl-test"}
    end

    test "handles error response", %{server: server} do
      line = error_chunk("API rate limit exceeded", "rate_limit_error")

      assert :ok = StreamLineUtils.handle_stream_line(server, line)
      refute_received _
    end

    test "handles error response from JSON", %{server: server} do
      json_string = ~s({"error":{"message":"Invalid request","type":"invalid_request_error"}})

      assert :ok = StreamLineUtils.handle_stream_line(server, json_string)
      refute_received _
    end

    test "handles unmatched message structure", %{server: server} do
      line = ~s(data: {"choices":[],"id":"test"})

      assert :ok = StreamLineUtils.handle_stream_line(server, line)
      refute_received _
    end

    test "handles invalid JSON gracefully", %{server: server} do
      line = "data: {invalid json}"

      assert :ok = StreamLineUtils.handle_stream_line(server, line)
      refute_received _
    end
  end

  describe "Reasoning content" do
    test "handles single reasoning content chunk", %{server: server} do
      line = reasoning_chunk("The")

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", "The"}
    end

    test "handles multiple reasoning content chunks", %{server: server} do
      lines = [
        reasoning_chunk("The"),
        reasoning_chunk(" user"),
        reasoning_chunk(" asks")
      ]

      for line <- lines do
        StreamLineUtils.handle_stream_line(server, line)
      end

      assert_received {:ai_reasoning_chunk, "chatcmpl-test", "The"}
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", " user"}
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", " asks"}
    end
  end

  describe "Text response content" do
    test "handles single text content chunk", %{server: server} do
      line = text_chunk("Hello")

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:ai_text_chunk, "chatcmpl-test", "Hello"}
    end

    test "handles multiple text content chunks", %{server: server} do
      lines = [
        text_chunk("I"),
        text_chunk("'m"),
        text_chunk(" happy")
      ]

      for line <- lines do
        StreamLineUtils.handle_stream_line(server, line)
      end

      assert_received {:ai_text_chunk, "chatcmpl-test", "I"}
      assert_received {:ai_text_chunk, "chatcmpl-test", "'m"}
      assert_received {:ai_text_chunk, "chatcmpl-test", " happy"}
    end

    test "handles finish_reason stop", %{server: server} do
      line = stop_chunk()

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:ai_text_stream_finish, "chatcmpl-test"}
    end
  end

  describe "Tool calling" do
    test "handles tool call start", %{server: server} do
      line = tool_call_start_chunk("get_weather", ~s({"location), 0, "call_123")

      StreamLineUtils.handle_stream_line(server, line)

      assert_received {:ai_tool_call_start, "chatcmpl-test",
                       {"get_weather", ~s({"location), 0, "call_123"}}
    end

    test "handles tool call middle", %{server: server} do
      line = tool_call_middle_chunk(~s(": "San Francisco"))

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:ai_tool_call_middle, "chatcmpl-test", {~s(": "San Francisco"), 0}}
    end

    test "handles tool call end", %{server: server} do
      line = tool_call_end_chunk()

      StreamLineUtils.handle_stream_line(server, line)
      assert_received {:ai_tool_call_end, "chatcmpl-test"}
    end

    test "handles complete tool call flow", %{server: server} do
      # Start tool call
      start_line = tool_call_start_chunk("get_weather", ~s({"location), 0, "call_123")
      StreamLineUtils.handle_stream_line(server, start_line)

      assert_received {:ai_tool_call_start, "chatcmpl-test",
                       {"get_weather", ~s({"location), 0, "call_123"}}

      # Middle of tool call
      middle_line = tool_call_middle_chunk(~s(": "NYC"}))
      StreamLineUtils.handle_stream_line(server, middle_line)
      assert_received {:ai_tool_call_middle, "chatcmpl-test", {~s(": "NYC"}), 0}}

      # End tool call
      end_line = tool_call_end_chunk()
      StreamLineUtils.handle_stream_line(server, end_line)
      assert_received {:ai_tool_call_end, "chatcmpl-test"}
    end
  end

  describe "Integration tests" do
    test "handles complete conversation flow", %{server: server} do
      # Start
      StreamLineUtils.handle_stream_line(server, start_response())
      assert_received {:start_new_ai_response, "chatcmpl-test"}

      # Reasoning chunks
      StreamLineUtils.handle_stream_line(server, reasoning_chunk("Think"))
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", "Think"}

      StreamLineUtils.handle_stream_line(server, reasoning_chunk("ing..."))
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", "ing..."}

      # Content chunks
      StreamLineUtils.handle_stream_line(server, text_chunk("Hello"))
      assert_received {:ai_text_chunk, "chatcmpl-test", "Hello"}

      StreamLineUtils.handle_stream_line(server, text_chunk(" world"))
      assert_received {:ai_text_chunk, "chatcmpl-test", " world"}

      # End
      StreamLineUtils.handle_stream_line(server, stop_chunk())
      assert_received {:ai_text_stream_finish, "chatcmpl-test"}

      # Done marker
      StreamLineUtils.handle_stream_line(server, "data: [DONE]")
      refute_received _
    end

    test "handles conversation with tool call", %{server: server} do
      # Start
      StreamLineUtils.handle_stream_line(server, start_response())
      assert_received {:start_new_ai_response, "chatcmpl-test"}

      # Reasoning
      StreamLineUtils.handle_stream_line(server, reasoning_chunk("Need to check weather"))
      assert_received {:ai_reasoning_chunk, "chatcmpl-test", "Need to check weather"}

      # Tool call
      StreamLineUtils.handle_stream_line(
        server,
        tool_call_start_chunk("get_weather", ~s({"loc), 0, "call_1")
      )

      assert_received {:ai_tool_call_start, "chatcmpl-test",
                       {"get_weather", ~s({"loc), 0, "call_1"}}

      StreamLineUtils.handle_stream_line(server, tool_call_middle_chunk(~s(ation"})))
      assert_received {:ai_tool_call_middle, "chatcmpl-test", {~s(ation"}), 0}}

      StreamLineUtils.handle_stream_line(server, tool_call_end_chunk())
      assert_received {:ai_tool_call_end, "chatcmpl-test"}

      # Done
      StreamLineUtils.handle_stream_line(server, "data: [DONE]")
      refute_received _
    end
  end
end
