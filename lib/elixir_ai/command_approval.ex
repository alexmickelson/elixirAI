defmodule ElixirAi.CommandApproval do
  @moduledoc """
  Classifies sandbox commands as auto-allowed or requiring human approval.

  Default policy: reads are auto-allowed, writes require approval.
  Users can customize per-conversation via `approval_policy`.

  The classifier examines the first command in a pipeline and every command
  after `&&`, `||`, or `;` chain operators. If ANY segment requires approval,
  the whole command requires approval.
  """

  @doc """
  Classify a shell command string against a policy.
  Returns `:auto_allow` or `{:needs_approval, reason}`.
  """
  def classify(command, policy \\ default_policy()) do
    segments = split_chain_segments(command)

    case Enum.find_value(segments, fn seg -> check_segment(seg, policy) end) do
      nil -> :auto_allow
      reason -> {:needs_approval, reason}
    end
  end

  @doc """
  Returns the default policy map. Users override specific keys.
  """
  def default_policy do
    %{
      auto_allow:
        MapSet.new([
          "cat",
          "head",
          "tail",
          "less",
          "more",
          "grep",
          "egrep",
          "fgrep",
          "rg",
          "find",
          "ls",
          "tree",
          "file",
          "stat",
          "du",
          "df",
          "wc",
          "sort",
          "uniq",
          "tr",
          "cut",
          "paste",
          "column",
          "awk",
          "sed",
          "echo",
          "printf",
          "true",
          "false",
          "date",
          "cal",
          "env",
          "printenv",
          "whoami",
          "id",
          "uname",
          "hostname",
          "jq",
          "diff",
          "comm",
          "basename",
          "dirname",
          "realpath",
          "readlink",
          "which",
          "type",
          "command",
          "test",
          "expr",
          "bc",
          "seq",
          "man",
          "help",
          "info",
          "git log",
          "git status",
          "git diff",
          "git show",
          "git branch",
          "git tag"
        ]),
      always_approve:
        MapSet.new([
          "rm",
          "rmdir",
          "mkfs",
          "dd",
          "chmod",
          "chown",
          "chgrp",
          "kill",
          "killall",
          "pkill",
          "shutdown",
          "reboot",
          "halt",
          "mount",
          "umount",
          "apt",
          "apt-get",
          "dpkg",
          "pip",
          "pip3",
          "npm",
          "yarn",
          "git push",
          "git commit",
          "git reset",
          "git checkout",
          "git merge",
          "git rebase",
          "docker",
          "kubectl",
          "sudo",
          "su",
          "ssh",
          "scp",
          "rsync",
          "nc",
          "ncat",
          "socat"
        ]),
      write_flags: ["-i", "--in-place", "-w", "--write", "-o", "--output"],
      write_patterns: [~r/\s>(?!>)\s*\S/, ~r/\s>>\s*\S/, ~r/\btee\b/]
    }
  end

  @doc """
  Merge user overrides on top of the default policy.
  """
  def merged_policy(nil), do: default_policy()

  def merged_policy(user_overrides) when is_map(user_overrides) do
    base = default_policy()

    additions = MapSet.new(Map.get(user_overrides, "auto_allow_additions", []))
    restrictions = MapSet.new(Map.get(user_overrides, "require_approval_additions", []))

    auto_allow =
      base.auto_allow
      |> MapSet.union(additions)
      |> MapSet.difference(restrictions)

    always_approve =
      base.always_approve
      |> MapSet.union(restrictions)
      |> MapSet.difference(additions)

    %{base | auto_allow: auto_allow, always_approve: always_approve}
  end

  # -- Internal ---------------------------------------------------------------

  defp split_chain_segments(command) do
    command
    |> String.split(~r/\s*(?:&&|\|\||;)\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp check_segment(segment, policy) do
    cmd = extract_command_name(segment)

    cond do
      two_word_match?(segment, policy.always_approve) ->
        "#{two_word_cmd(segment)} requires approval"

      MapSet.member?(policy.always_approve, cmd) ->
        "#{cmd} requires approval"

      two_word_match?(segment, policy.auto_allow) ->
        nil

      MapSet.member?(policy.auto_allow, cmd) ->
        check_write_escalation(segment, cmd, policy)

      true ->
        "unknown command '#{cmd}' requires approval"
    end
  end

  defp extract_command_name(segment) do
    segment |> String.split(~r/\s+/, parts: 2) |> List.first() |> to_string()
  end

  defp two_word_cmd(segment) do
    segment |> String.split(~r/\s+/, parts: 3) |> Enum.take(2) |> Enum.join(" ")
  end

  defp two_word_match?(segment, set) do
    MapSet.member?(set, two_word_cmd(segment))
  end

  defp check_write_escalation(segment, cmd, policy) do
    has_write_flag =
      Enum.any?(policy.write_flags, fn flag ->
        String.contains?(segment, flag)
      end)

    has_write_pattern =
      Enum.any?(policy.write_patterns, fn pattern ->
        Regex.match?(pattern, segment)
      end)

    cond do
      has_write_flag -> "#{cmd} with write flag requires approval"
      has_write_pattern -> "output redirect requires approval"
      true -> nil
    end
  end
end
