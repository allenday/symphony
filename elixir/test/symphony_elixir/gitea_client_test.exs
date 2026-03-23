defmodule SymphonyElixir.GiteaClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Gitea.Client
  alias SymphonyElixir.Linear.Issue

  test "maps closed duplicate and wontfix labels to terminal states" do
    duplicate_issue =
      Client.normalize_issue_for_test(%{
        "number" => 12,
        "title" => "dup",
        "body" => "duplicate",
        "state" => "closed",
        "labels" => [%{"name" => "duplicate"}],
        "created_at" => "2026-03-19T00:00:00Z",
        "updated_at" => "2026-03-19T00:00:00Z"
      })

    assert duplicate_issue.state == "Duplicate"

    cancelled_issue =
      Client.normalize_issue_for_test(%{
        "number" => 13,
        "title" => "wontfix",
        "body" => "cancelled",
        "state" => "closed",
        "labels" => [%{"name" => "wontfix"}]
      })

    assert cancelled_issue.state == "Cancelled"

    done_issue =
      Client.normalize_issue_for_test(%{
        "number" => 14,
        "title" => "done",
        "body" => "closed",
        "state" => "closed",
        "labels" => [%{"name" => "bug"}]
      })

    assert done_issue.state == "Done"
  end

  test "maps open issues without state labels to Todo" do
    issue =
      Client.normalize_issue_for_test(%{
        "number" => 15,
        "title" => "todo",
        "body" => "open",
        "state" => "open",
        "labels" => [%{"name" => "bug"}]
      })

    assert issue.state == "Todo"
    assert issue.id == "15"
    assert issue.identifier == "#15"
  end

  test "normalizes issue comments for prompt context" do
    issue =
      Client.normalize_issue_for_test(
        %{
          "number" => 16,
          "title" => "commented",
          "body" => "open",
          "state" => "open",
          "labels" => []
        },
        [
          %{
            "id" => 42,
            "body" => "Execution log: complete",
            "created_at" => "2026-03-21T18:40:32Z",
            "updated_at" => "2026-03-21T18:40:32Z",
            "html_url" => "https://example.test/comment/42",
            "user" => %{"login" => "builder"}
          }
        ]
      )

    assert [
             %{
               id: 42,
               author: "builder",
               body: "Execution log: complete",
               url: "https://example.test/comment/42",
               created_at: %DateTime{}
             }
           ] = issue.comments
  end

  test "candidate selection filters by active states and assignee" do
    issues = [
      %Issue{id: "1", state: "Todo", assignee_id: "builder"},
      %Issue{id: "2", state: "In Progress", assignee_id: "Builder"},
      %Issue{id: "3", state: "Backlog", assignee_id: "builder"},
      %Issue{id: "4", state: "Todo", assignee_id: "alice"},
      %Issue{id: "5", state: "Done", assignee_id: "builder"},
      %Issue{id: "6", state: "Todo", assignee_id: nil}
    ]

    selected =
      Client.select_candidate_issues_for_test(issues, ["Todo", "In Progress"], " builder ")

    assert Enum.map(selected, & &1.id) == ["1", "2"]
  end

  test "candidate selection treats To Do and Todo as equivalent states" do
    issues = [
      %Issue{id: "1", state: "Todo", assignee_id: "builder"},
      %Issue{id: "2", state: "To Do", assignee_id: "builder"},
      %Issue{id: "3", state: "In Progress", assignee_id: "builder"}
    ]

    selected =
      Client.select_candidate_issues_for_test(issues, ["To Do", "In Progress"], "builder")

    assert Enum.map(selected, & &1.id) == ["1", "2", "3"]
  end

  test "reviewer watchdog can pick done issues still assigned to builder" do
    issues = [
      %Issue{id: "1", state: "Done", assignee_id: "builder"},
      %Issue{id: "2", state: "Done", assignee_id: "reviewer"},
      %Issue{id: "3", state: "Done", assignee_id: "alice"}
    ]

    selected = Client.select_candidate_issues_for_test(issues, ["Done"], "reviewer")

    assert Enum.map(selected, & &1.id) == ["1", "2"]
  end

  test "candidate selection does not enforce assignee when blank" do
    issues = [
      %Issue{id: "1", state: "Todo", assignee_id: "builder"},
      %Issue{id: "2", state: "In Progress", assignee_id: nil},
      %Issue{id: "3", state: "Done", assignee_id: "builder"}
    ]

    selected =
      Client.select_candidate_issues_for_test(issues, ["Todo", "In Progress"], "   ")

    assert Enum.map(selected, & &1.id) == ["1", "2"]
  end

  test "parses project board HTML into column and issue mappings" do
    html = """
    <div id="project-board">
      <div class="project-column" data-id="2">
        <div class="project-column-title-text">Todo</div>
        <div class="ui cards">
          <div class="issue-card" data-issue="393"></div>
        </div>
      </div>
      <div class="project-column" data-id="3">
        <div class="project-column-title-text">In Progress</div>
        <div class="ui cards">
          <div class="issue-card" data-issue="999"></div>
        </div>
      </div>
    </div>
    """

    snapshot = Client.parse_project_board_html_for_test(html)

    assert snapshot.columns_by_key["todo"] == 2
    assert snapshot.columns_by_key["inprogress"] == 3
    assert snapshot.issue_column_key_by_internal_id[393] == "todo"
    assert snapshot.issue_column_key_by_internal_id[999] == "inprogress"
  end

  test "normalizes board column names with suffixes and punctuation" do
    assert Client.board_column_key_for_test("Backlog2") == "backlog"
    assert Client.board_column_key_for_test("In Progress") == "inprogress"
    assert Client.board_column_key_for_test("Human-Review") == "humanreview"
  end

  test "extracts linked pull number from latest issue comments" do
    comments = [
      %{"body" => "PR: https://gitea.example.test/org/repo/pulls/11"},
      %{"body" => "latest link https://gitea.example.test/org/repo/pulls/57"}
    ]

    assert {:ok, 57} = Client.extract_linked_pull_number_for_test(comments)
  end

  test "requested reviewer validation detects missing reviewer handoff" do
    pull = %{
      "number" => 57,
      "requested_reviewers" => [%{"login" => "alice"}, %{"login" => "bob"}]
    }

    assert {:error, {:missing_requested_reviewer, 57}} =
             Client.requested_reviewer_present_for_test(pull, "reviewer")
  end

  test "required pr ci validation demands success for woodpecker pr context" do
    statuses = [
      %{"context" => "ci/woodpecker/pr/woodpecker", "status" => "failure"}
    ]

    assert {:error, {:pr_ci_not_success, "ci/woodpecker/pr/woodpecker", "failure"}} =
             Client.required_pr_ci_success_for_test(statuses)
  end

  test "controller remediation comment uses typed schema with anomaly id" do
    issue = %Issue{id: "30", identifier: "symphony#30"}

    comment =
      Client.review_handoff_failure_comment_for_test(
        issue,
        {:missing_requested_reviewer, 57},
        "builder"
      )

    assert comment =~ "## Symphony Controller"
    assert comment =~ "anomaly_id: A04_REVIEW_HANDOFF_MISSING_REVIEWER_REQUEST"
    assert comment =~ "issue_identifier: symphony#30"
    assert comment =~ "next_owner: builder"
    assert comment =~ "actions_taken: comment, assign:builder, state:To Do"
  end
end
