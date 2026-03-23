defmodule SymphonyElixir.Gitea.Client do
  @moduledoc """
  Thin Gitea REST client for polling and mutating repository issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, tracker} <- tracker_config(),
         {:ok, issues} <- fetch_repo_issues(tracker, "open") do
      board_snapshot = maybe_fetch_project_board_snapshot(tracker)
      normalized = Enum.map(issues, &normalize_issue(&1, board_snapshot))
      selected = select_candidate_issues(normalized, tracker.active_states, tracker.assignee)
      {:ok, maybe_enforce_review_handoff_guard(tracker, selected)}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), [map()]) :: Issue.t()
  def normalize_issue_for_test(issue, comments \\ []) when is_map(issue) and is_list(comments),
    do: normalize_issue(issue, nil, comments)

  @doc false
  @spec parse_project_board_html_for_test(String.t()) :: map()
  def parse_project_board_html_for_test(html) when is_binary(html),
    do: parse_project_board_html(html)

  @doc false
  @spec board_column_key_for_test(String.t()) :: String.t()
  def board_column_key_for_test(name) when is_binary(name), do: board_column_key(name)

  @doc false
  @spec select_candidate_issues_for_test([Issue.t()], [String.t()], String.t() | nil) :: [
          Issue.t()
        ]
  def select_candidate_issues_for_test(issues, active_states, assignee),
    do: select_candidate_issues(issues, active_states, assignee)

  @doc false
  @spec extract_linked_pull_number_for_test([map()]) :: {:ok, pos_integer()} | {:error, term()}
  def extract_linked_pull_number_for_test(comments), do: extract_linked_pull_number(comments)

  @doc false
  @spec requested_reviewer_present_for_test(map(), String.t()) :: :ok | {:error, term()}
  def requested_reviewer_present_for_test(pull, expected_login),
    do: requested_reviewer_present?(pull, expected_login)

  @doc false
  @spec required_pr_ci_success_for_test([map()]) :: :ok | {:error, term()}
  def required_pr_ci_success_for_test(statuses), do: required_pr_ci_success?(statuses)

  @doc false
  @spec review_handoff_failure_comment_for_test(Issue.t(), term(), String.t()) :: String.t()
  def review_handoff_failure_comment_for_test(issue, reason, builder_assignee),
    do: review_handoff_failure_comment(issue, reason, builder_assignee)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    requested = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    if MapSet.size(requested) == 0 do
      {:ok, []}
    else
      with {:ok, tracker} <- tracker_config(),
           {:ok, open_issues} <- fetch_repo_issues(tracker, "open"),
           {:ok, closed_issues} <- fetch_repo_issues(tracker, "closed") do
        issues =
          (open_issues ++ closed_issues)
          |> Enum.map(&normalize_issue/1)
          |> Enum.filter(&(normalize_state(&1.state) in requested))

        {:ok, issues}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, tracker} <- tracker_config() do
          board_snapshot = maybe_fetch_project_board_snapshot(tracker)

          ids
          |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
            case fetch_issue(tracker, issue_id) do
              {:ok, issue} ->
                comments = fetch_issue_comments_for_context(tracker, issue_id)
                {:cont, {:ok, [normalize_issue(issue, board_snapshot, comments) | acc]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, issues} -> {:ok, Enum.reverse(issues)}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, tracker} <- tracker_config(),
         {:ok, _response} <-
           request(
             tracker,
             :post,
             "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}/comments",
             %{body: body}
           ) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, tracker} <- tracker_config(),
         {:ok, issue} <- fetch_issue(tracker, issue_id) do
      with :ok <- transition_issue_state(tracker, issue, state_name) do
        maybe_move_issue_on_project_board(tracker, issue, state_name)
      end
    end
  end

  defp transition_issue_state(tracker, issue, state_name) do
    normalized_target = normalize_state(state_name)

    cond do
      normalized_target == "closed" ->
        close_issue(tracker, issue)

      normalized_target == "done" ->
        # "Done" is a board lifecycle state, not necessarily an issue close signal.
        # Keep the issue open so a reviewer role can pick it up.
        open_issue(tracker, issue)

      normalized_target in ["cancelled", "canceled"] ->
        with :ok <- close_issue(tracker, issue),
             :ok <- ensure_issue_labels(tracker, issue, ["wontfix"]) do
          :ok
        end

      normalized_target == "duplicate" ->
        with :ok <- close_issue(tracker, issue),
             :ok <- ensure_issue_labels(tracker, issue, ["duplicate"]) do
          :ok
        end

      true ->
        open_issue(tracker, issue)
    end
  end

  defp open_issue(tracker, issue) do
    if normalize_state(Map.get(issue, "state")) == "open" do
      :ok
    else
      case request(
             tracker,
             :patch,
             "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue["number"]}",
             %{state: "open"}
           ) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp close_issue(tracker, issue) do
    if normalize_state(Map.get(issue, "state")) == "closed" do
      :ok
    else
      case request(
             tracker,
             :patch,
             "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue["number"]}",
             %{state: "closed"}
           ) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_issue_labels(tracker, issue, labels_to_add) do
    existing_labels =
      issue
      |> Map.get("labels", [])
      |> Enum.map(fn label -> Map.get(label, "name") end)
      |> Enum.filter(&is_binary/1)

    all_labels =
      (existing_labels ++ labels_to_add)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case request(
           tracker,
           :put,
           "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue["number"]}/labels",
           %{labels: all_labels}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue(tracker, issue_id) do
    request(
      tracker,
      :get,
      "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}"
    )
  end

  defp fetch_issue_comments_for_context(tracker, issue_id) do
    case fetch_issue_comments(tracker, issue_id) do
      {:ok, comments} ->
        comments

      {:error, reason} ->
        Logger.warning("Failed to fetch Gitea issue comments for issue_id=#{issue_id}: #{inspect(reason)}")

        []
    end
  end

  defp fetch_issue_comments(tracker, issue_id) do
    do_fetch_issue_comments(tracker, issue_id, 1, [])
  end

  defp do_fetch_issue_comments(tracker, issue_id, page, acc) do
    path =
      "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}/comments?page=#{page}&limit=#{@page_size}"

    case request(tracker, :get, path) do
      {:ok, comments} when is_list(comments) ->
        updated = acc ++ comments

        if length(comments) < @page_size do
          {:ok, updated}
        else
          do_fetch_issue_comments(tracker, issue_id, page + 1, updated)
        end

      {:ok, _other} ->
        {:error, :invalid_gitea_comments_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_repo_issues(tracker, state) do
    do_fetch_repo_issues(tracker, state, 1, [])
  end

  defp do_fetch_repo_issues(tracker, state, page, acc) do
    path =
      "/repos/#{tracker.owner}/#{tracker.repo}/issues?state=#{state}&type=issues&page=#{page}&limit=#{@page_size}"

    case request(tracker, :get, path) do
      {:ok, issues} when is_list(issues) ->
        updated = acc ++ issues

        if length(issues) < @page_size do
          {:ok, updated}
        else
          do_fetch_repo_issues(tracker, state, page + 1, updated)
        end

      {:ok, _other} ->
        {:error, :invalid_gitea_issues_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(tracker, method, path, body \\ nil) do
    case request_raw(tracker, method, path, body) do
      {:ok, status, response_body} when status in 200..299 ->
        {:ok, response_body}

      {:ok, status, response_body} ->
        {:error, {:gitea_api_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_raw(tracker, method, path, body) do
    url = api_base(tracker) <> path

    req =
      Req.new(
        method: method,
        url: url,
        headers: [
          {"authorization", "token #{tracker.api_key}"},
          {"accept", "application/json"}
        ],
        receive_timeout: Config.settings!().codex.read_timeout_ms
      )

    req = if is_nil(body), do: req, else: Req.merge(req, json: body)

    case Req.request(req) do
      {:ok, %{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, {:gitea_api_request, reason}}
    end
  end

  defp web_request(tracker, method, path, body, opts) do
    url = web_base(tracker) <> path
    csrf_required = Keyword.get(opts, :csrf_required, false)
    extra_headers = Keyword.get(opts, :headers, [])

    with {:ok, headers} <- web_headers(tracker, csrf_required) do
      req =
        Req.new(
          method: method,
          url: url,
          headers: headers ++ extra_headers,
          receive_timeout: Config.settings!().codex.read_timeout_ms
        )

      req = if is_nil(body), do: req, else: Req.merge(req, json: body)

      case Req.request(req) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: status, body: response_body}} ->
          {:error, {:gitea_web_status, status, response_body}}

        {:error, reason} ->
          {:error, {:gitea_web_request, reason}}
      end
    end
  end

  defp web_headers(tracker, csrf_required) do
    cookie = normalize_secret_header(tracker.web_cookie)
    csrf_token = normalize_secret_header(tracker.web_csrf_token)

    cond do
      csrf_required and is_nil(cookie) ->
        {:error, :missing_gitea_web_cookie}

      csrf_required and is_nil(csrf_token) ->
        {:error, :missing_gitea_web_csrf_token}

      true ->
        headers =
          [
            {"accept", "application/json"},
            {"content-type", "application/json"}
          ]
          |> maybe_put_cookie(cookie)
          |> maybe_put_csrf(csrf_token)

        {:ok, headers}
    end
  end

  defp maybe_put_cookie(headers, nil), do: headers
  defp maybe_put_cookie(headers, cookie), do: [{"cookie", cookie} | headers]

  defp maybe_put_csrf(headers, nil), do: headers
  defp maybe_put_csrf(headers, csrf_token), do: [{"x-csrf-token", csrf_token} | headers]

  defp tracker_config do
    tracker = Config.settings!().tracker

    if tracker.kind == "gitea" do
      {:ok, tracker}
    else
      {:error, {:unsupported_tracker_kind, tracker.kind}}
    end
  end

  defp api_base(tracker) do
    tracker.endpoint
    |> String.trim()
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1")
  end

  defp web_base(tracker) do
    tracker.endpoint
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp select_candidate_issues(issues, active_states, assignee) do
    active = MapSet.new(Enum.map(active_states, &state_match_key/1))
    normalized_assignee = normalize_assignee(assignee)

    issues
    |> Enum.filter(&(state_match_key(&1.state) in active))
    |> Enum.filter(fn issue ->
      case normalized_assignee do
        nil ->
          true

        expected ->
          issue_assignee = normalize_assignee(issue.assignee_id)

          issue_assignee == expected or
            reviewer_watchdog_takeover?(expected, issue, issue_assignee)
      end
    end)
  end

  defp maybe_enforce_review_handoff_guard(tracker, issues) when is_list(issues) do
    if normalize_assignee(tracker.assignee) == "reviewer" do
      issues
      |> Enum.reduce([], fn issue, acc ->
        case review_handoff_guard_result(tracker, issue) do
          :ok ->
            [issue | acc]

          {:error, reason} ->
            enforce_review_handoff_remediation(tracker, issue, reason)
            acc
        end
      end)
      |> Enum.reverse()
    else
      issues
    end
  end

  defp maybe_enforce_review_handoff_guard(_tracker, issues), do: issues

  defp review_handoff_guard_result(_tracker, %Issue{} = issue)
       when not is_binary(issue.state),
       do: :ok

  defp review_handoff_guard_result(tracker, %Issue{} = issue) do
    if state_match_key(issue.state) == "done" do
      with {:ok, comments} <- fetch_issue_comments(tracker, issue.id),
           {:ok, pr_number} <- extract_linked_pull_number(comments),
           {:ok, pull} <- fetch_pull_request(tracker, pr_number),
           :ok <- requested_reviewer_present?(pull, "reviewer"),
           {:ok, head_sha} <- pull_head_sha(pull),
           {:ok, statuses} <- fetch_commit_statuses(tracker, head_sha),
           :ok <- required_pr_ci_success?(statuses) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp review_handoff_guard_result(_tracker, _issue), do: :ok

  defp enforce_review_handoff_remediation(tracker, %Issue{} = issue, reason) do
    key = {:review_handoff_guard, issue.id, inspect(reason)}

    warn_once(key, fn ->
      "Review handoff guard failed for issue=#{issue.identifier || issue.id}: #{inspect(reason)}"
    end)

    builder_assignee = System.get_env("GITEA_BUILDER_ASSIGNEE", "builder")

    _ =
      create_comment(
        issue.id,
        review_handoff_failure_comment(issue, reason, builder_assignee)
      )

    _ = set_issue_assignee(tracker, issue.id, builder_assignee)
    _ = update_issue_state(issue.id, "To Do")
    :ok
  end

  defp enforce_review_handoff_remediation(_tracker, _issue, _reason), do: :ok

  defp review_handoff_failure_comment(issue, reason, builder_assignee) do
    anomaly_id = controller_anomaly_id(reason)
    detected_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    ## Symphony Controller
    anomaly_id: #{anomaly_id}
    detected_at: #{detected_at}
    issue_identifier: #{issue.identifier || issue.id}
    reason: #{humanize_review_guard_reason(reason)}
    actions_taken: comment, assign:#{builder_assignee}, state:To Do
    next_owner: #{builder_assignee}
    expected_recovery: add reviewer request on linked PR and ensure ci/woodpecker/pr/woodpecker is success, then hand off to Done again
    """
  end

  defp controller_anomaly_id({:missing_linked_pull, _issue_id}),
    do: "A03_REVIEW_HANDOFF_MISSING_LINKED_PR"

  defp controller_anomaly_id({:missing_requested_reviewer, _pr_number}),
    do: "A04_REVIEW_HANDOFF_MISSING_REVIEWER_REQUEST"

  defp controller_anomaly_id({:missing_pr_ci_status, _context}),
    do: "A05_REVIEW_HANDOFF_MISSING_PR_CI_STATUS"

  defp controller_anomaly_id({:pr_ci_not_success, _context, _status}),
    do: "A06_REVIEW_HANDOFF_PR_CI_NOT_GREEN"

  defp controller_anomaly_id(_reason), do: "A00_UNKNOWN_CONTROLLER_GUARD"

  defp humanize_review_guard_reason({:missing_linked_pull, _issue_id}),
    do: "No linked PR found in issue comments."

  defp humanize_review_guard_reason({:missing_requested_reviewer, pr_number}),
    do: "PR ##{pr_number} does not include `reviewer` in requested reviewers."

  defp humanize_review_guard_reason({:missing_pr_ci_status, context}),
    do: "PR required CI status `#{context}` is missing."

  defp humanize_review_guard_reason({:pr_ci_not_success, context, status}),
    do: "PR required CI status `#{context}` is `#{status}` (expected `success`)."

  defp humanize_review_guard_reason(other), do: inspect(other)

  defp extract_linked_pull_number(comments) when is_list(comments) do
    comments
    |> Enum.reverse()
    |> Enum.find_value(fn comment ->
      body = Map.get(comment, "body") || Map.get(comment, :body)

      if is_binary(body) do
        case Regex.run(~r{/pulls/(\d+)}, body) do
          [_, raw_number] ->
            case Integer.parse(raw_number) do
              {parsed, ""} when parsed > 0 -> parsed
              _ -> nil
            end

          _ ->
            nil
        end
      else
        nil
      end
    end)
    |> case do
      nil -> {:error, {:missing_linked_pull, nil}}
      number -> {:ok, number}
    end
  end

  defp extract_linked_pull_number(_comments), do: {:error, {:missing_linked_pull, nil}}

  defp fetch_pull_request(tracker, pull_number) when is_integer(pull_number) and pull_number > 0 do
    request(tracker, :get, "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pull_number}")
  end

  defp fetch_pull_request(_tracker, _pull_number), do: {:error, :invalid_pull_number}

  defp requested_reviewer_present?(pull, expected_login) when is_map(pull) and is_binary(expected_login) do
    reviewers =
      pull
      |> Map.get("requested_reviewers", [])
      |> Enum.map(fn reviewer ->
        reviewer
        |> Map.get("login")
        |> normalize_assignee()
      end)
      |> Enum.reject(&is_nil/1)

    if normalize_assignee(expected_login) in reviewers do
      :ok
    else
      {:error, {:missing_requested_reviewer, Map.get(pull, "number")}}
    end
  end

  defp requested_reviewer_present?(_pull, _expected_login), do: {:error, :invalid_pull_payload}

  defp pull_head_sha(pull) when is_map(pull) do
    case get_in(pull, ["head", "sha"]) do
      sha when is_binary(sha) and byte_size(sha) > 0 -> {:ok, sha}
      _ -> {:error, :missing_pull_head_sha}
    end
  end

  defp pull_head_sha(_pull), do: {:error, :invalid_pull_payload}

  defp fetch_commit_statuses(tracker, sha) when is_binary(sha) and byte_size(sha) > 0 do
    request(tracker, :get, "/repos/#{tracker.owner}/#{tracker.repo}/commits/#{sha}/statuses")
  end

  defp fetch_commit_statuses(_tracker, _sha), do: {:error, :invalid_commit_sha}

  defp required_pr_ci_success?(statuses) when is_list(statuses) do
    required_context = "ci/woodpecker/pr/woodpecker"

    case Enum.find(statuses, fn status -> Map.get(status, "context") == required_context end) do
      nil ->
        {:error, {:missing_pr_ci_status, required_context}}

      status ->
        case normalize_state(Map.get(status, "status")) do
          "success" -> :ok
          other -> {:error, {:pr_ci_not_success, required_context, other}}
        end
    end
  end

  defp required_pr_ci_success?(_statuses), do: {:error, :invalid_pr_ci_status_payload}

  defp set_issue_assignee(tracker, issue_id, assignee)
       when is_binary(issue_id) and is_binary(assignee) do
    case request(
           tracker,
           :patch,
           "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}",
           %{assignee: assignee}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_issue_assignee(_tracker, _issue_id, _assignee), do: {:error, :invalid_assignee_payload}

  defp reviewer_watchdog_takeover?(
         "reviewer",
         %Issue{} = issue,
         issue_assignee
       ) do
    reviewer_watchdog_enabled?() and
      state_match_key(issue.state) == "done" and
      issue_assignee in [nil, "builder"]
  end

  defp reviewer_watchdog_takeover?(_expected, _issue, _issue_assignee), do: false

  defp reviewer_watchdog_enabled? do
    case System.get_env("GITEA_REVIEWER_WATCHDOG") do
      nil -> true
      value when is_binary(value) -> String.trim(value) != "0"
      _ -> true
    end
  end

  defp state_match_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp state_match_key(_value), do: ""

  defp normalize_assignee(nil), do: nil

  defp normalize_assignee(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee(_value), do: nil

  defp maybe_fetch_project_board_snapshot(%{project_id: nil}), do: nil

  defp maybe_fetch_project_board_snapshot(tracker) do
    path = "/#{tracker.owner}/#{tracker.repo}/projects/#{tracker.project_id}"

    case web_request(tracker, :get, path, nil, headers: [{"accept", "text/html"}]) do
      {:ok, html} when is_binary(html) ->
        parse_project_board_html(html)

      {:error, reason} ->
        warn_once(
          {:board_fetch_failed, tracker.endpoint, tracker.owner, tracker.repo, tracker.project_id},
          fn ->
            "Failed to fetch Gitea board snapshot for project_id=#{tracker.project_id}: #{inspect(reason)}"
          end
        )

        nil
    end
  end

  defp maybe_move_issue_on_project_board(%{project_id: nil}, _issue, _state_name), do: :ok

  defp maybe_move_issue_on_project_board(tracker, issue, state_name) do
    with {:ok, issue_internal_id} <- parse_issue_internal_id(issue),
         {:ok, target_column_key} <- state_to_board_column_key(state_name),
         %{} = snapshot <- maybe_fetch_project_board_snapshot(tracker),
         {:ok, target_column_id} <- board_column_id(snapshot, target_column_key) do
      if Map.get(snapshot.issue_column_key_by_internal_id, issue_internal_id) == target_column_key do
        :ok
      else
        move_issue_on_board(tracker, issue_internal_id, target_column_id)
      end
    else
      {:skip, _reason} ->
        :ok

      nil ->
        :ok

      {:error, :missing_gitea_web_cookie} ->
        warn_once({:missing_web_cookie, tracker.endpoint}, fn ->
          "Gitea board move skipped: missing tracker.web_cookie / GITEA_WEB_COOKIE"
        end)

        :ok

      {:error, :missing_gitea_web_csrf_token} ->
        warn_once({:missing_web_csrf, tracker.endpoint}, fn ->
          "Gitea board move skipped: missing tracker.web_csrf_token / GITEA_WEB_CSRF_TOKEN"
        end)

        :ok

      {:error, reason} ->
        warn_once({:board_move_failed, tracker.endpoint, inspect(reason)}, fn ->
          "Gitea board move failed: #{inspect(reason)}"
        end)

        :ok
    end
  end

  defp move_issue_on_board(tracker, issue_internal_id, target_column_id) do
    path =
      "/#{tracker.owner}/#{tracker.repo}/projects/#{tracker.project_id}/#{target_column_id}/move"

    payload = %{"issues" => [%{"issueID" => issue_internal_id, "sorting" => 0}]}

    case web_request(tracker, :post, path, payload, csrf_required: true) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp board_column_id(snapshot, target_column_key) do
    case Map.get(snapshot.columns_by_key, target_column_key) do
      nil -> {:skip, :no_matching_board_column}
      id -> {:ok, id}
    end
  end

  defp parse_issue_internal_id(%{"id" => id}) when is_integer(id), do: {:ok, id}

  defp parse_issue_internal_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:skip, :invalid_issue_internal_id}
    end
  end

  defp parse_issue_internal_id(_issue), do: {:skip, :missing_issue_internal_id}

  defp parse_project_board_html(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        columns =
          document
          |> Floki.find("#project-board .project-column")
          |> Enum.reduce(
            %{columns_by_key: %{}, issue_column_key_by_internal_id: %{}},
            fn column_node, acc ->
              column_id =
                column_node
                |> Floki.attribute("data-id")
                |> List.first()
                |> parse_integer_or_nil()

              title =
                column_node
                |> Floki.find(".project-column-title-text")
                |> Floki.text()
                |> String.trim()

              column_key = board_column_key(title)

              updated_columns =
                if is_integer(column_id) and column_key != "" do
                  Map.put(acc.columns_by_key, column_key, column_id)
                else
                  acc.columns_by_key
                end

              issue_map =
                column_node
                |> Floki.find(".issue-card[data-issue]")
                |> Enum.reduce(acc.issue_column_key_by_internal_id, fn issue_node, issue_acc ->
                  internal_id =
                    issue_node
                    |> Floki.attribute("data-issue")
                    |> List.first()
                    |> parse_integer_or_nil()

                  if is_integer(internal_id) and column_key != "" do
                    Map.put(issue_acc, internal_id, column_key)
                  else
                    issue_acc
                  end
                end)

              %{columns_by_key: updated_columns, issue_column_key_by_internal_id: issue_map}
            end
          )

        columns

      {:error, _reason} ->
        %{columns_by_key: %{}, issue_column_key_by_internal_id: %{}}
    end
  end

  defp parse_integer_or_nil(nil), do: nil

  defp parse_integer_or_nil(value) when is_integer(value), do: value

  defp parse_integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer_or_nil(_value), do: nil

  defp state_to_board_column_key(state_name) when is_binary(state_name) do
    normalized = board_column_key(state_name)

    key =
      case normalized do
        "closed" -> "done"
        "canceled" -> "cancelled"
        other -> other
      end

    if key == "", do: {:skip, :empty_state}, else: {:ok, key}
  end

  defp state_to_board_column_key(_state_name), do: {:skip, :invalid_state}

  defp board_column_key(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z]/u, "")
  end

  defp board_column_key(_name), do: ""

  defp normalize_secret_header(nil), do: nil

  defp normalize_secret_header(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_secret_header(_value), do: nil

  defp warn_once(key, message_builder) do
    warning_key = {__MODULE__, :warn_once, key}

    unless :persistent_term.get(warning_key, false) do
      Logger.warning(message_builder.())
      :persistent_term.put(warning_key, true)
    end
  end

  defp normalize_issue(issue, board_snapshot \\ nil, comments \\ [])
       when is_map(issue) and is_list(comments) do
    labels =
      issue
      |> Map.get("labels", [])
      |> Enum.map(fn label -> Map.get(label, "name") end)
      |> Enum.filter(&is_binary/1)

    %Issue{
      id: issue_id(issue),
      identifier: issue_identifier(issue),
      title: Map.get(issue, "title"),
      description: Map.get(issue, "body"),
      priority: nil,
      state: mapped_state(issue, labels, board_snapshot),
      branch_name: nil,
      url: Map.get(issue, "html_url"),
      assignee_id: issue_assignee(issue),
      comments: normalize_comments(comments),
      labels: labels,
      assigned_to_worker: true,
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp issue_id(issue) do
    issue
    |> Map.get("number")
    |> to_string()
  end

  defp issue_identifier(issue) do
    repo = get_in(issue, ["repository", "name"])
    number = Map.get(issue, "number")

    cond do
      is_binary(repo) and is_integer(number) -> "#{repo}##{number}"
      is_integer(number) -> "##{number}"
      true -> issue_id(issue)
    end
  end

  defp issue_assignee(issue) do
    case Map.get(issue, "assignee") do
      %{"login" => login} when is_binary(login) -> login
      _ -> nil
    end
  end

  defp normalize_comments(comments) when is_list(comments) do
    comments
    |> Enum.flat_map(fn
      %{} = comment ->
        [
          %{
            id: Map.get(comment, "id"),
            author: comment_author(comment),
            body: normalize_comment_body(Map.get(comment, "body")),
            created_at: parse_datetime(Map.get(comment, "created_at")),
            updated_at: parse_datetime(Map.get(comment, "updated_at")),
            url: Map.get(comment, "html_url")
          }
        ]

      _ ->
        []
    end)
  end

  defp comment_author(comment) when is_map(comment) do
    case Map.get(comment, "user") do
      %{"login" => login} when is_binary(login) -> login
      _ -> nil
    end
  end

  defp normalize_comment_body(body) when is_binary(body), do: body
  defp normalize_comment_body(_body), do: nil

  defp mapped_state(issue, labels, board_snapshot) do
    case board_state(issue, board_snapshot) do
      nil ->
        if normalize_state(Map.get(issue, "state")) == "closed" do
          terminal_state_from_labels(labels)
        else
          open_state_from_labels(labels)
        end

      board_state_name ->
        board_state_name
    end
  end

  defp board_state(_issue, nil), do: nil

  defp board_state(issue, %{issue_column_key_by_internal_id: issue_columns}) do
    internal_id = Map.get(issue, "id")

    with id when is_integer(id) <- parse_integer_or_nil(internal_id),
         column_key when is_binary(column_key) <- Map.get(issue_columns, id) do
      state_from_board_column_key(column_key)
    else
      _ -> nil
    end
  end

  defp state_from_board_column_key("backlog"), do: "Backlog"
  defp state_from_board_column_key("todo"), do: "Todo"
  defp state_from_board_column_key("inprogress"), do: "In Progress"
  defp state_from_board_column_key("humanreview"), do: "Human Review"
  defp state_from_board_column_key("merging"), do: "Merging"
  defp state_from_board_column_key("rework"), do: "Rework"
  defp state_from_board_column_key("done"), do: "Done"
  defp state_from_board_column_key("cancelled"), do: "Cancelled"
  defp state_from_board_column_key("duplicate"), do: "Duplicate"
  defp state_from_board_column_key(_other), do: nil

  defp terminal_state_from_labels(labels) do
    normalized = labels |> Enum.map(&normalize_state/1) |> MapSet.new()

    cond do
      MapSet.member?(normalized, "duplicate") -> "Duplicate"
      MapSet.member?(normalized, "wontfix") -> "Cancelled"
      true -> "Done"
    end
  end

  defp open_state_from_labels(labels) do
    normalized = labels |> Enum.map(&normalize_state/1)

    cond do
      Enum.any?(normalized, &(&1 in ["backlog"])) ->
        "Backlog"

      Enum.any?(normalized, &(&1 in ["todo"])) ->
        "Todo"

      Enum.any?(normalized, &(&1 in ["in progress", "in-progress", "in_progress"])) ->
        "In Progress"

      Enum.any?(normalized, &(&1 in ["human review", "human-review", "human_review"])) ->
        "Human Review"

      Enum.any?(normalized, &(&1 in ["merging"])) ->
        "Merging"

      Enum.any?(normalized, &(&1 in ["rework"])) ->
        "Rework"

      true ->
        "Todo"
    end
  end

  defp issue_index(issue_id) do
    issue_id
    |> String.trim()
    |> Integer.parse()
    |> case do
      {index, ""} ->
        index

      _ ->
        raise ArgumentError,
              "Gitea issue id must be a numeric issue index, got: #{inspect(issue_id)}"
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_value), do: ""
end
