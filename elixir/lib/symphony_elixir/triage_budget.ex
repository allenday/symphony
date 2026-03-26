defmodule SymphonyElixir.TriageBudget do
  @moduledoc """
  Parses the `## Symphony Triage` metadata block from issue comments.
  """

  alias SymphonyElixir.Linear.Issue

  @type t :: %{
          estimate_tokens: pos_integer() | nil,
          soft_cap_tokens: pos_integer() | nil,
          hard_cap_tokens: pos_integer() | nil,
          ready: boolean() | nil
        }

  @empty %{estimate_tokens: nil, soft_cap_tokens: nil, hard_cap_tokens: nil, ready: nil}

  @spec from_issue(Issue.t() | term()) :: t() | nil
  def from_issue(%Issue{comments: comments}) when is_list(comments) do
    from_comments(comments)
  end

  def from_issue(_issue), do: nil

  @spec from_comments([map()]) :: t() | nil
  def from_comments(comments) when is_list(comments) do
    comments
    |> Enum.reverse()
    |> Enum.find_value(&parse_comment/1)
  end

  def from_comments(_comments), do: nil

  @spec hard_cap_tokens(t() | nil) :: pos_integer() | nil
  def hard_cap_tokens(%{} = budget), do: positive_integer(Map.get(budget, :hard_cap_tokens))
  def hard_cap_tokens(_budget), do: nil

  @spec soft_cap_tokens(t() | nil) :: pos_integer() | nil
  def soft_cap_tokens(%{} = budget), do: positive_integer(Map.get(budget, :soft_cap_tokens))
  def soft_cap_tokens(_budget), do: nil

  defp parse_comment(comment) when is_map(comment) do
    body = Map.get(comment, :body) || Map.get(comment, "body")

    if is_binary(body) and String.contains?(String.downcase(body), "## symphony triage") do
      parse_block(body)
    else
      nil
    end
  end

  defp parse_comment(_comment), do: nil

  defp parse_block(body) do
    parsed =
      body
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [raw_key, raw_value] ->
            key = normalize_key(raw_key)
            value = String.trim(raw_value)
            maybe_put_field(acc, key, value)

          _ ->
            acc
        end
      end)

    if map_size(parsed) == 0 do
      nil
    else
      parsed = Map.merge(@empty, parsed)
      normalize_budget(parsed)
    end
  end

  defp normalize_key(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/u, "")
  end

  defp maybe_put_field(acc, "estimate_tokens", value) do
    maybe_put_positive_integer(acc, :estimate_tokens, value)
  end

  defp maybe_put_field(acc, "soft_cap_tokens", value) do
    maybe_put_positive_integer(acc, :soft_cap_tokens, value)
  end

  defp maybe_put_field(acc, "hard_cap_tokens", value) do
    maybe_put_positive_integer(acc, :hard_cap_tokens, value)
  end

  defp maybe_put_field(acc, "ready", value) do
    case parse_bool(value) do
      nil -> acc
      parsed -> Map.put(acc, :ready, parsed)
    end
  end

  defp maybe_put_field(acc, _key, _value), do: acc

  defp maybe_put_positive_integer(acc, key, value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> Map.put(acc, key, parsed)
      _ -> acc
    end
  end

  defp parse_bool(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "yes" -> true
      "1" -> true
      "false" -> false
      "no" -> false
      "0" -> false
      _ -> nil
    end
  end

  defp parse_bool(_value), do: nil

  defp normalize_budget(%{} = budget) do
    soft = Map.get(budget, :soft_cap_tokens)
    hard = Map.get(budget, :hard_cap_tokens)

    case {positive_integer(soft), positive_integer(hard)} do
      {soft_cap, hard_cap} when is_integer(soft_cap) and is_integer(hard_cap) and hard_cap < soft_cap ->
        %{budget | hard_cap_tokens: soft_cap}

      _ ->
        budget
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
