defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @comment_context_limit 8
  @comment_body_limit 1_200

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> append_issue_comment_context(issue)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp append_issue_comment_context(prompt, %{comments: comments})
       when is_binary(prompt) and is_list(comments) do
    case render_issue_comment_context(comments) do
      nil -> prompt
      context -> prompt <> "\n\n" <> context
    end
  end

  defp append_issue_comment_context(prompt, _issue), do: prompt

  defp render_issue_comment_context(comments) when is_list(comments) do
    comments =
      comments
      |> Enum.filter(&renderable_comment?/1)
      |> Enum.take(-@comment_context_limit)

    case comments do
      [] ->
        nil

      visible_comments ->
        rendered_comments =
          visible_comments
          |> Enum.with_index(1)
          |> Enum.map_join("\n\n", fn {comment, index} ->
            [
              "Comment #{index}",
              "author=#{comment[:author] || "unknown"}",
              "created_at=#{render_comment_timestamp(comment[:created_at])}",
              "body:",
              truncate_comment_body(comment[:body])
            ]
            |> Enum.join("\n")
          end)

        """
        Existing issue comments are included below as execution-log context. Reuse the current workpad when possible. If a terminal completion summary matching your intended final note already exists, do not post a near-duplicate terminal summary comment.

        #{rendered_comments}
        """
        |> String.trim_trailing()
    end
  end

  defp render_issue_comment_context(_comments), do: nil

  defp renderable_comment?(comment) when is_map(comment) do
    is_binary(comment[:body]) and String.trim(comment[:body]) != ""
  end

  defp renderable_comment?(_comment), do: false

  defp render_comment_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp render_comment_timestamp(_timestamp), do: "unknown"

  defp truncate_comment_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    if String.length(trimmed) <= @comment_body_limit do
      trimmed
    else
      String.slice(trimmed, 0, @comment_body_limit) <> "... (truncated)"
    end
  end
end
