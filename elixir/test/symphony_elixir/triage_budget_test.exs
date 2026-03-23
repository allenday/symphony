defmodule SymphonyElixir.TriageBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TriageBudget

  test "parses triage block from latest matching comment" do
    issue = %Issue{
      comments: [
        %{body: "noise"},
        %{
          body: """
          ## Symphony Triage
          estimate_tokens: 120000
          soft_cap_tokens: 180000
          hard_cap_tokens: 250000
          ready: true
          """
        }
      ]
    }

    assert %{
             estimate_tokens: 120_000,
             soft_cap_tokens: 180_000,
             hard_cap_tokens: 250_000,
             ready: true
           } = TriageBudget.from_issue(issue)
  end

  test "normalizes invalid hard cap below soft cap" do
    issue = %Issue{
      comments: [
        %{
          body: """
          ## Symphony Triage
          soft_cap_tokens: 200000
          hard_cap_tokens: 150000
          """
        }
      ]
    }

    assert %{soft_cap_tokens: 200_000, hard_cap_tokens: 200_000} = TriageBudget.from_issue(issue)
  end

  test "returns nil when triage block is missing" do
    issue = %Issue{comments: [%{body: "## Codex Workpad\nstatus: running"}]}

    assert TriageBudget.from_issue(issue) == nil
  end
end
