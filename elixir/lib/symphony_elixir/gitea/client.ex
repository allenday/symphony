defmodule SymphonyElixir.Gitea.Client do
  @moduledoc """
  Thin Gitea REST client for polling and mutating repository issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, TriageBudget}

  @page_size 50

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, tracker} <- tracker_config(),
         {:ok, issues} <- fetch_repo_issues(tracker, "open") do
      board_snapshot = maybe_fetch_project_board_snapshot(tracker)
      normalized = Enum.map(issues, &normalize_issue(&1, board_snapshot))
      role = tracker_role(tracker)
      selected = select_candidate_issues_for_role(normalized, issues, tracker.active_states, tracker.assignee, role)
      {:ok, maybe_enforce_candidate_guards(tracker, selected, issues, board_snapshot, role)}
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
  @spec select_controller_candidates_for_test([Issue.t()], [map()]) :: [Issue.t()]
  def select_controller_candidates_for_test(issues, raw_issues),
    do: select_controller_candidates(issues, raw_issues)

  @doc false
  @spec csrf_token_from_cookie_for_test(String.t() | nil) :: String.t() | nil
  def csrf_token_from_cookie_for_test(cookie), do: csrf_token_from_cookie(cookie)

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
  @spec controller_guard_comment_for_test(Issue.t(), term(), String.t(), String.t()) :: String.t()
  def controller_guard_comment_for_test(issue, reason, next_owner, target_state),
    do: controller_guard_comment(issue, reason, next_owner, target_state)

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
    do_fetch_issue_comments(tracker, issue_id, 1, [], comment_page_limit())
  end

  defp do_fetch_issue_comments(_tracker, _issue_id, page, acc, max_pages) when page > max_pages,
    do: {:ok, acc}

  defp do_fetch_issue_comments(tracker, issue_id, page, acc, max_pages) do
    path =
      "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}/comments?page=#{page}&limit=#{@page_size}"

    case request(tracker, :get, path) do
      {:ok, comments} when is_list(comments) ->
        updated = acc ++ comments

        if length(comments) < @page_size or page >= max_pages do
          {:ok, updated}
        else
          do_fetch_issue_comments(tracker, issue_id, page + 1, updated, max_pages)
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

    csrf_token =
      normalize_secret_header(tracker.web_csrf_token) ||
        csrf_token_from_cookie(cookie)

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

  defp maybe_enforce_candidate_guards(tracker, issues, raw_issues, board_snapshot, role)
       when is_list(issues) do
    raw_by_issue_number =
      raw_issues
      |> Enum.filter(&is_map/1)
      |> Map.new(fn raw -> {to_string(Map.get(raw, "number")), raw} end)

    issues
    |> Enum.reduce([], fn issue, acc ->
      case candidate_guard_result(tracker, role, issue, raw_by_issue_number, board_snapshot) do
        :ok ->
          [issue | acc]

        {:error, reason} ->
          enforce_candidate_guard_remediation(tracker, role, issue, reason)
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_enforce_candidate_guards(_tracker, issues, _raw_issues, _board_snapshot, _role), do: issues

  defp candidate_guard_result(tracker, role, %Issue{} = issue, raw_by_issue_number, board_snapshot) do
    with :ok <- project_membership_guard_result(issue, raw_by_issue_number, board_snapshot),
         :ok <- triage_ready_guard_result(tracker, role, issue),
         :ok <- backlog_open_pr_guard_result(tracker, role, issue),
         :ok <- review_handoff_guard_result(tracker, role, issue) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_guard_result(_tracker, _role, _issue, _raw_by_issue_number, _board_snapshot), do: :ok

  defp project_membership_guard_result(%Issue{} = issue, raw_by_issue_number, board_snapshot) do
    if is_map(board_snapshot) and map_size(Map.get(board_snapshot, :issue_column_key_by_internal_id, %{})) > 0 do
      raw_issue = Map.get(raw_by_issue_number, issue.id)
      internal_id = raw_issue && parse_integer_or_nil(Map.get(raw_issue, "id"))
      board_map = Map.get(board_snapshot, :issue_column_key_by_internal_id, %{})

      if is_integer(internal_id) and Map.has_key?(board_map, internal_id) do
        :ok
      else
        {:error, :missing_project_membership}
      end
    else
      :ok
    end
  end

  defp project_membership_guard_result(_issue, _raw_by_issue_number, _board_snapshot), do: :ok

  defp triage_ready_guard_result(tracker, role, %Issue{} = issue) do
    if role in ["builder", "controller"] and state_match_key(issue.state) in ["todo", "inprogress"] do
      with {:ok, comments} <- fetch_issue_comments(tracker, issue.id),
           budget when is_map(budget) <- TriageBudget.from_comments(comments),
           true <- Map.get(budget, :ready) == true do
        :ok
      else
        nil -> {:error, :missing_triage_budget}
        false -> {:error, :triage_not_ready}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp triage_ready_guard_result(_tracker, _role, _issue), do: :ok

  defp backlog_open_pr_guard_result(tracker, "controller", %Issue{} = issue) do
    if state_match_key(issue.state) == "backlog" do
      with {:ok, comments} <- fetch_issue_comments(tracker, issue.id),
           {:ok, pr_number} <- extract_linked_pull_number(comments),
           {:ok, pull} <- fetch_pull_request(tracker, pr_number),
           true <- normalize_state(Map.get(pull, "state")) == "open" do
        {:error, {:backlog_with_open_pr, pr_number}}
      else
        {:error, {:missing_linked_pull, _issue_id}} -> :ok
        false -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp backlog_open_pr_guard_result(_tracker, _role, _issue), do: :ok

  defp review_handoff_guard_result(_tracker, role, %Issue{} = _issue)
       when role not in ["reviewer", "controller"],
       do: :ok

  defp review_handoff_guard_result(_tracker, _role, %Issue{} = issue)
       when not is_binary(issue.state),
       do: :ok

  # Reviewer policy: linked PR handoff should be evaluated even when issue
  # dependencies are open. Dependency closure is a controller/planner concern.
  defp review_handoff_guard_result(tracker, "reviewer", %Issue{} = issue) do
    if state_match_key(issue.state) == "done" do
      with {:ok, comments} <- fetch_issue_comments(tracker, issue.id),
           {:ok, pr_number} <- extract_linked_pull_number(comments),
           {:ok, pull} <- fetch_pull_request(tracker, pr_number),
           :ok <- stale_open_pr_guard_result(pull),
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

  # Controller policy: keep dependency gating so system-level anomaly handling
  # can nudge blocked issue graphs without stalling reviewer dispatch.
  defp review_handoff_guard_result(tracker, "controller", %Issue{} = issue) do
    if state_match_key(issue.state) == "done" do
      with :ok <- dependency_block_guard_result(tracker, issue),
           {:ok, comments} <- fetch_issue_comments(tracker, issue.id),
           {:ok, pr_number} <- extract_linked_pull_number(comments),
           {:ok, pull} <- fetch_pull_request(tracker, pr_number),
           :ok <- stale_open_pr_guard_result(pull),
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

  defp review_handoff_guard_result(_tracker, _role, _issue), do: :ok

  defp stale_open_pr_guard_result(pull) when is_map(pull) do
    state = pull |> Map.get("state") |> normalize_state()
    changed_files = Map.get(pull, "changed_files")
    additions = Map.get(pull, "additions")
    deletions = Map.get(pull, "deletions")
    number = Map.get(pull, "number")

    if state == "open" and changed_files == 0 and additions == 0 and deletions == 0 do
      {:error, {:stale_open_pr_already_in_base, number}}
    else
      :ok
    end
  end

  defp stale_open_pr_guard_result(_pull), do: :ok

  defp dependency_block_guard_result(tracker, %Issue{} = issue) do
    case fetch_issue_dependencies(tracker, issue.id) do
      {:ok, dependencies} when is_list(dependencies) ->
        open_dependencies =
          dependencies
          |> Enum.filter(fn dep -> normalize_state(Map.get(dep, "state")) != "closed" end)
          |> Enum.map(fn dep -> Map.get(dep, "number") end)
          |> Enum.filter(&is_integer/1)

        if open_dependencies == [] do
          :ok
        else
          {:error, {:dependency_blocked, open_dependencies}}
        end

      {:ok, _other} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_candidate_guard_remediation(tracker, role, %Issue{} = issue, reason) do
    key = {:candidate_guard, issue.id, role, inspect(reason)}

    warn_once(key, fn ->
      "Candidate guard failed role=#{role} issue=#{issue.identifier || issue.id}: #{inspect(reason)}"
    end)

    builder_assignee = System.get_env("GITEA_BUILDER_ASSIGNEE", "builder")
    planner_assignee = System.get_env("GITEA_TRIAGE_ASSIGNEE", "planner")

    case reason do
      :missing_triage_budget ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          create_comment(issue.id, controller_guard_comment(issue, reason, planner_assignee, "Backlog"))
        end)

        run_controller_remediation_action(role, issue, reason, :assign_planner, fn ->
          set_issue_assignee(tracker, issue.id, planner_assignee)
        end)

        run_controller_remediation_action(role, issue, reason, :state_backlog, fn ->
          update_issue_state(issue.id, "Backlog")
        end)

        :ok

      :triage_not_ready ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          create_comment(issue.id, controller_guard_comment(issue, reason, planner_assignee, "Backlog"))
        end)

        run_controller_remediation_action(role, issue, reason, :assign_planner, fn ->
          set_issue_assignee(tracker, issue.id, planner_assignee)
        end)

        run_controller_remediation_action(role, issue, reason, :state_backlog, fn ->
          update_issue_state(issue.id, "Backlog")
        end)

        :ok

      :missing_project_membership ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          maybe_create_controller_comment(tracker, issue, reason, planner_assignee, "Backlog")
        end)

        run_controller_remediation_action(role, issue, reason, :assign_planner, fn ->
          set_issue_assignee(tracker, issue.id, planner_assignee)
        end)

        run_controller_remediation_action(role, issue, reason, :state_backlog, fn ->
          update_issue_state(issue.id, "Backlog")
        end)

        :ok

      {:dependency_blocked, _deps} ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          maybe_create_controller_comment(
            tracker,
            issue,
            reason,
            normalize_assignee(issue.assignee_id) || "reviewer",
            "Done"
          )
        end)

        :ok

      {:stale_open_pr_already_in_base, pr_number} ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          maybe_create_controller_comment(tracker, issue, reason, "reviewer", "Closed")
        end)

        run_controller_remediation_action(role, issue, reason, {:close_pr, pr_number}, fn ->
          close_pull_request(tracker, pr_number)
        end)

        :ok

      {:backlog_with_open_pr, pr_number} ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          maybe_create_controller_comment(tracker, issue, reason, "reviewer", "Done")
        end)

        run_controller_remediation_action(role, issue, reason, :assign_reviewer, fn ->
          set_issue_assignee(tracker, issue.id, "reviewer")
        end)

        run_controller_remediation_action(role, issue, reason, :state_done, fn ->
          update_issue_state(issue.id, "Done")
        end)

        run_controller_remediation_action(role, issue, reason, {:request_reviewer, pr_number}, fn ->
          request_pull_reviewer(tracker, pr_number, "reviewer")
        end)

        :ok

      _ ->
        run_controller_remediation_action(role, issue, reason, :comment, fn ->
          maybe_create_controller_comment(tracker, issue, reason, builder_assignee, "To Do")
        end)

        run_controller_remediation_action(role, issue, reason, :assign_builder, fn ->
          set_issue_assignee(tracker, issue.id, builder_assignee)
        end)

        run_controller_remediation_action(role, issue, reason, :state_todo, fn ->
          update_issue_state(issue.id, "To Do")
        end)

        :ok
    end
  end

  defp enforce_candidate_guard_remediation(_tracker, _role, _issue, _reason), do: :ok

  defp run_controller_remediation_action(role, issue, reason, action, fun)
       when is_function(fun, 0) do
    result =
      try do
        fun.()
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      end

    anomaly_id = controller_anomaly_id(reason)
    issue_identifier = issue.identifier || issue.id || "unknown"
    normalized_result = remediation_result_status(result)

    Logger.info(
      "controller_remediation role=#{role} issue=#{issue_identifier} anomaly_id=#{anomaly_id} action=#{remediation_action_name(action)} result=#{normalized_result} detail=#{inspect(result)}"
    )

    result
  end

  defp remediation_result_status(:ok), do: "ok"
  defp remediation_result_status({:ok, _}), do: "ok"
  defp remediation_result_status({:skip, _}), do: "skip"
  defp remediation_result_status({:error, _}), do: "error"
  defp remediation_result_status(_other), do: "unknown"

  defp remediation_action_name({:close_pr, number}), do: "close_pr:#{number}"
  defp remediation_action_name({:request_reviewer, number}), do: "request_reviewer:#{number}"
  defp remediation_action_name(action) when is_atom(action), do: Atom.to_string(action)
  defp remediation_action_name(action), do: to_string(action)

  defp maybe_create_controller_comment(tracker, issue, reason, next_owner, target_state) do
    anomaly_id = controller_anomaly_id(reason)

    if controller_comment_on_cooldown?(issue.id, anomaly_id) or
         recent_controller_comment_exists?(tracker, issue.id, anomaly_id) do
      :ok
    else
      result = create_comment(issue.id, controller_guard_comment(issue, reason, next_owner, target_state))
      mark_controller_comment_posted(issue.id, anomaly_id)
      result
    end
  end

  defp recent_controller_comment_exists?(tracker, issue_id, anomaly_id) do
    case fetch_issue_comments(tracker, issue_id) do
      {:ok, comments} when is_list(comments) ->
        comments
        |> Enum.reverse()
        |> Enum.take(20)
        |> Enum.any?(fn comment ->
          body = Map.get(comment, "body")

          is_binary(body) and String.contains?(body, "## Symphony Controller") and
            String.contains?(body, "anomaly_id: #{anomaly_id}")
        end)

      _ ->
        false
    end
  end

  defp controller_comment_on_cooldown?(issue_id, anomaly_id) do
    key = {__MODULE__, :controller_comment_cooldown, issue_id, anomaly_id}
    posted_at = :persistent_term.get(key, 0)
    now = System.monotonic_time(:second)
    now - posted_at < 300
  end

  defp mark_controller_comment_posted(issue_id, anomaly_id) do
    key = {__MODULE__, :controller_comment_cooldown, issue_id, anomaly_id}
    :persistent_term.put(key, System.monotonic_time(:second))
  end

  defp controller_guard_comment(issue, reason, next_owner, target_state) do
    anomaly_id = controller_anomaly_id(reason)
    detected_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    ## Symphony Controller
    anomaly_id: #{anomaly_id}
    detected_at: #{detected_at}
    issue_identifier: #{issue.identifier || issue.id}
    reason: #{humanize_review_guard_reason(reason)}
    actions_taken: #{controller_actions_taken(reason, next_owner, target_state)}
    next_owner: #{next_owner}
    expected_recovery: #{controller_expected_recovery(reason)}
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

  defp controller_anomaly_id(:missing_triage_budget), do: "A01_TRIAGE_MISSING_BUDGET"
  defp controller_anomaly_id(:triage_not_ready), do: "A02_TRIAGE_NOT_READY_PROMOTED"
  defp controller_anomaly_id({:dependency_blocked, _deps}), do: "A08_REVIEW_ACCEPTED_BUT_NOT_CLOSABLE"
  defp controller_anomaly_id(:missing_project_membership), do: "A09_PROJECT_MEMBERSHIP_MISSING"
  defp controller_anomaly_id({:stale_open_pr_already_in_base, _}), do: "A10_STALE_OPEN_PR_ALREADY_IN_BASE"
  defp controller_anomaly_id({:backlog_with_open_pr, _}), do: "A11_BACKLOG_WITH_OPEN_PR"

  defp controller_anomaly_id(_reason), do: "A00_UNKNOWN_CONTROLLER_GUARD"

  defp humanize_review_guard_reason({:missing_linked_pull, _issue_id}),
    do: "No linked PR found in issue comments."

  defp humanize_review_guard_reason({:missing_requested_reviewer, pr_number}),
    do: "PR ##{pr_number} does not include `reviewer` in requested reviewers."

  defp humanize_review_guard_reason({:missing_pr_ci_status, context}),
    do: "PR required CI status `#{context}` is missing."

  defp humanize_review_guard_reason({:pr_ci_not_success, context, status}),
    do: "PR required CI status `#{context}` is `#{status}` (expected `success`)."

  defp humanize_review_guard_reason(:missing_triage_budget),
    do: "Issue moved into active delivery state without a `## Symphony Triage` budget block."

  defp humanize_review_guard_reason(:triage_not_ready),
    do: "Issue triage block exists but `ready` is not `true`."

  defp humanize_review_guard_reason({:dependency_blocked, deps}),
    do: "Issue closure is blocked by open dependencies: #{Enum.map_join(deps, ", ", &"##{&1}")}."

  defp humanize_review_guard_reason(:missing_project_membership),
    do: "Issue is not present on the configured project board."

  defp humanize_review_guard_reason({:stale_open_pr_already_in_base, pr_number}),
    do: "PR ##{pr_number} is still open but has no diff versus base (already in target branch)."

  defp humanize_review_guard_reason({:backlog_with_open_pr, pr_number}),
    do: "Issue is still in Backlog but linked PR ##{pr_number} is already open."

  defp humanize_review_guard_reason(other), do: inspect(other)

  defp controller_expected_recovery({:missing_linked_pull, _issue_id}),
    do: "link the implementation PR in issue comments, then hand off to Done again"

  defp controller_expected_recovery({:missing_requested_reviewer, _pr_number}),
    do: "request reviewer on the linked PR and keep handoff evidence in the issue"

  defp controller_expected_recovery({:missing_pr_ci_status, context}),
    do: "publish required PR status context `#{context}` and re-handoff"

  defp controller_expected_recovery({:pr_ci_not_success, context, _status}),
    do: "fix PR CI so `#{context}` is success, then hand off to Done again"

  defp controller_expected_recovery(:missing_triage_budget),
    do: "triage role must add `## Symphony Triage` metadata and set ready=true before promotion"

  defp controller_expected_recovery(:triage_not_ready),
    do: "triage role must resolve scope blockers and set ready=true before promotion"

  defp controller_expected_recovery({:dependency_blocked, _deps}),
    do: "close or unlink blocking dependencies, then retry close"

  defp controller_expected_recovery(:missing_project_membership),
    do: "add the issue to the configured project board and place it in the intended column"

  defp controller_expected_recovery({:stale_open_pr_already_in_base, _}),
    do: "close stale PR; keep parent issue open for normal state-machine handling"

  defp controller_expected_recovery({:backlog_with_open_pr, _}),
    do: "promote issue to Done and hand off PR to reviewer queue"

  defp controller_expected_recovery(_reason),
    do: "inspect controller logs and resolve prerequisites before retrying handoff"

  defp controller_actions_taken({:stale_open_pr_already_in_base, pr_number}, _next_owner, _target_state),
    do: "comment, close_pr:#{pr_number}"

  defp controller_actions_taken({:backlog_with_open_pr, pr_number}, _next_owner, _target_state),
    do: "comment, assign:reviewer, state:Done, request_reviewer:reviewer, pr:#{pr_number}"

  defp controller_actions_taken(_reason, next_owner, target_state),
    do: "comment, assign:#{next_owner}, state:#{target_state}"

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

  defp fetch_issue_dependencies(tracker, issue_id) when is_binary(issue_id) do
    request(
      tracker,
      :get,
      "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_index(issue_id)}/dependencies"
    )
  end

  defp fetch_issue_dependencies(_tracker, _issue_id), do: {:error, :invalid_issue_id}

  defp fetch_pull_request(tracker, pull_number) when is_integer(pull_number) and pull_number > 0 do
    request(tracker, :get, "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pull_number}")
  end

  defp fetch_pull_request(_tracker, _pull_number), do: {:error, :invalid_pull_number}

  defp close_pull_request(tracker, pull_number)
       when is_integer(pull_number) and pull_number > 0 do
    case request(
           tracker,
           :patch,
           "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pull_number}",
           %{state: "closed"}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_pull_request(_tracker, _pull_number), do: {:error, :invalid_pull_number}

  defp request_pull_reviewer(tracker, pull_number, reviewer)
       when is_integer(pull_number) and pull_number > 0 and is_binary(reviewer) do
    case request(
           tracker,
           :post,
           "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pull_number}/requested_reviewers",
           %{reviewers: [reviewer]}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_pull_reviewer(_tracker, _pull_number, _reviewer), do: {:error, :invalid_reviewer_request}

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

  defp tracker_role(tracker) do
    if controller_role_mode?() do
      "controller"
    else
      normalize_assignee(Map.get(tracker, :assignee))
    end
  end

  defp controller_role_mode? do
    explicit =
      case System.get_env("SYMPHONY_CONTROLLER_MODE") do
        value when is_binary(value) -> String.downcase(String.trim(value))
        _ -> nil
      end

    cond do
      explicit in ["1", "true", "yes"] ->
        true

      explicit in ["0", "false", "no"] ->
        false

      true ->
        case System.get_env("SYMPHONY_WORKFLOW_FILE") do
          path when is_binary(path) ->
            path
            |> Path.basename()
            |> String.downcase()
            |> String.contains?("controller")

          _ ->
            false
        end
    end
  end

  defp select_candidate_issues_for_role(issues, raw_issues, _active_states, _assignee, "controller"),
    do: select_controller_candidates(issues, raw_issues)

  defp select_candidate_issues_for_role(issues, _raw_issues, active_states, assignee, _role),
    do: select_candidate_issues(issues, active_states, assignee)

  defp select_controller_candidates(issues, raw_issues) do
    pull_issue_numbers =
      raw_issues
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(not is_nil(Map.get(&1, "pull_request"))))
      |> Enum.map(&(Map.get(&1, "number") |> to_string()))
      |> MapSet.new()

    Enum.reject(issues, fn %Issue{id: id} -> id in pull_issue_numbers end)
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
        Logger.info(
          "board_move issue=#{Map.get(issue, "number")} internal_id=#{issue_internal_id} target_state=#{state_name} target_column=#{target_column_key} outcome=already_in_target"
        )

        :ok
      else
        case move_issue_on_board(tracker, issue_internal_id, target_column_id) do
          :ok ->
            Logger.info(
              "board_move issue=#{Map.get(issue, "number")} internal_id=#{issue_internal_id} target_state=#{state_name} target_column=#{target_column_key} target_column_id=#{target_column_id} outcome=moved"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "board_move issue=#{Map.get(issue, "number")} internal_id=#{issue_internal_id} target_state=#{state_name} target_column=#{target_column_key} target_column_id=#{target_column_id} outcome=error reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
      end
    else
      {:skip, reason} ->
        Logger.info(
          "board_move issue=#{Map.get(issue, "number")} target_state=#{state_name} outcome=skip reason=#{inspect(reason)}"
        )

        :ok

      nil ->
        Logger.info(
          "board_move issue=#{Map.get(issue, "number")} target_state=#{state_name} outcome=skip reason=no_board_snapshot"
        )

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

  defp comment_page_limit do
    case System.get_env("GITEA_COMMENT_PAGE_LIMIT") do
      nil ->
        3

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed >= 1 and parsed <= 20 -> parsed
          _ -> 3
        end

      _ ->
        3
    end
  end

  defp csrf_token_from_cookie(nil), do: nil

  defp csrf_token_from_cookie(cookie) when is_binary(cookie) do
    cookie
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn pair ->
      case String.split(pair, "=", parts: 2) do
        ["_csrf", token] when token != "" -> token
        _ -> nil
      end
    end)
  end

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
