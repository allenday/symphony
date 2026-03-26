defmodule SymphonyElixir.Gitea.RemediationRunner do
  @moduledoc false

  require Logger

  @default_max_attempts 2
  @default_backoff_ms 400

  @spec run(keyword()) :: term()
  def run(opts) when is_list(opts) do
    role = Keyword.fetch!(opts, :role)
    issue_identifier = Keyword.fetch!(opts, :issue_identifier)
    anomaly_id = Keyword.fetch!(opts, :anomaly_id)
    action = Keyword.fetch!(opts, :action)
    fun = Keyword.fetch!(opts, :fun)

    max_attempts =
      opts
      |> Keyword.get(:max_attempts, @default_max_attempts)
      |> normalize_max_attempts()

    backoff_ms =
      opts
      |> Keyword.get(:backoff_ms, @default_backoff_ms)
      |> normalize_backoff_ms()

    retryable? = Keyword.get(opts, :retryable?, &default_retryable?/1)

    do_run(
      role,
      issue_identifier,
      anomaly_id,
      action,
      fun,
      retryable?,
      max_attempts,
      backoff_ms,
      1
    )
  end

  defp do_run(role, issue_identifier, anomaly_id, action, fun, retryable?, max_attempts, backoff_ms, attempt) do
    result =
      try do
        fun.()
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      end

    retryable = retryable?.(result)

    if retryable and attempt < max_attempts do
      Logger.warning("controller_remediation_retry role=#{role} issue=#{issue_identifier} anomaly_id=#{anomaly_id} action=#{action} attempt=#{attempt} of=#{max_attempts} detail=#{inspect(result)}")

      Process.sleep(backoff_ms * attempt)

      do_run(
        role,
        issue_identifier,
        anomaly_id,
        action,
        fun,
        retryable?,
        max_attempts,
        backoff_ms,
        attempt + 1
      )
    else
      Logger.info(
        "controller_remediation role=#{role} issue=#{issue_identifier} anomaly_id=#{anomaly_id} action=#{action} attempts=#{attempt} result=#{result_status(result)} detail=#{inspect(result)}"
      )

      result
    end
  end

  defp result_status(:ok), do: "ok"
  defp result_status({:ok, _}), do: "ok"
  defp result_status({:skip, _}), do: "skip"
  defp result_status({:error, _}), do: "error"
  defp result_status(_other), do: "unknown"

  defp default_retryable?({:error, {:exception, _}}), do: false

  defp default_retryable?({:error, {:gitea_web_status, 500, body}}) when is_binary(body) do
    String.contains?(body, "MoveIssuesOnProjectColumn, all issues have to be added to a project first")
  end

  defp default_retryable?({:error, {:gitea_api_request, %Req.TransportError{reason: reason}}}),
    do: retryable_transport_reason?(reason)

  defp default_retryable?({:error, {:gitea_web_request, %Req.TransportError{reason: reason}}}),
    do: retryable_transport_reason?(reason)

  defp default_retryable?(_result), do: false

  defp retryable_transport_reason?(reason),
    do: reason in [:timeout, :closed, :econnrefused, :nxdomain, :enetunreach, :ehostunreach]

  defp normalize_max_attempts(value) when is_integer(value),
    do: value |> max(1) |> min(5)

  defp normalize_max_attempts(_value), do: @default_max_attempts

  defp normalize_backoff_ms(value) when is_integer(value),
    do: value |> max(50) |> min(5_000)

  defp normalize_backoff_ms(_value), do: @default_backoff_ms
end
