defmodule SymphonyElixir.DockerEntrypointTest do
  use ExUnit.Case, async: false

  @entrypoint_path Path.expand("../../docker/entrypoint.sh", __DIR__)
  @required_env ~w(
    GITEA_ENDPOINT
    GITEA_API_KEY
    GITEA_OWNER
    GITEA_REPO
    GITEA_PROJECT_ID
    SYMPHONY_REPO_URL
    SYMPHONY_REPO_BRANCH
    SYMPHONY_CODEX_COMMAND
  )

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-entrypoint-test-#{System.unique_integer([:positive])}"
      )

    auth_path = Path.join([test_root, ".codex", "auth.json"])
    patched_entrypoint_path = Path.join(test_root, "entrypoint.sh")

    File.mkdir_p!(Path.dirname(auth_path))
    File.write!(auth_path, "{}\n")

    @entrypoint_path
    |> File.read!()
    |> String.replace("/root/.codex/auth.json", auth_path)
    |> then(&File.write!(patched_entrypoint_path, &1))

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    {:ok, entrypoint_path: patched_entrypoint_path}
  end

  for key <- ~w(SYMPHONY_REPO_URL SYMPHONY_REPO_BRANCH) do
    test "entrypoint requires #{key}", %{entrypoint_path: entrypoint_path} do
      {output, 1} =
        System.cmd("bash", [entrypoint_path],
          cd: Path.expand("..", __DIR__),
          env: required_env(unquote(key), ""),
          stderr_to_stdout: true
        )

      assert output =~ "missing required env var: #{unquote(key)}"
      assert output =~ "configure it in .env before starting compose"
    end
  end

  test "entrypoint supports workflow file override env var", %{entrypoint_path: entrypoint_path} do
    content = File.read!(entrypoint_path)
    assert content =~ "SYMPHONY_WORKFLOW_FILE"
    assert content =~ "${SYMPHONY_WORKFLOW_FILE:-/opt/symphony/elixir/WORKFLOW.docker.gitea.md}"
  end

  test "entrypoint validates configured gitea project id by default", %{entrypoint_path: entrypoint_path} do
    content = File.read!(entrypoint_path)
    assert content =~ "GITEA_VALIDATE_PROJECT_ID"
    assert content =~ "configured GITEA_PROJECT_ID="
  end

  defp required_env(overridden_key, overridden_value) do
    Enum.map(@required_env, fn key ->
      value =
        if key == overridden_key do
          overridden_value
        else
          "test-#{String.downcase(key)}"
        end

      {key, value}
    end)
  end
end
