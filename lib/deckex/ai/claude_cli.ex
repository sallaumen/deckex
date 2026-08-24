defmodule Deckex.AI.ClaudeCli do
  @moduledoc """
  AI adapter backed by the `claude` CLI in headless mode. Runs
  `claude -p <prompt> --output-format json --json-schema <schema>` and returns
  the `structured_output` object from the result envelope.

  Two hardening details keep a CLI call from hanging its caller:

  - **stdin is redirected from `/dev/null`.** Spawned non-interactively from
    `phx.server` or an Oban worker, the CLI otherwise blocks forever waiting for
    piped input.
  - **The whole call is bounded by a timeout**, surfacing an error instead of an
    endless spinner.

  Headless runs get **no tools** unless the caller allows them explicitly.
  """
  @behaviour Deckex.AI.Client

  alias Deckex.AI.Usage
  alias Deckex.Cli
  alias Deckex.Error

  @default_timeout_ms 120_000

  # No default for `opts`: a default would generate a complete/2 that the
  # behaviour does not declare.
  @impl Deckex.AI.Client
  def complete(prompt, schema, opts) do
    cli_args = build_args(prompt, schema, opts)

    # Run through `sh` with stdin from /dev/null. `exec "$@"` forwards argv
    # verbatim, so the prompt and schema need no shell quoting and the CLI gets
    # an immediate EOF.
    argv = ["-c", ~s|exec "$@" < /dev/null|, "sh", executable() | cli_args]

    run(fn -> System.cmd("/bin/sh", argv, stderr_to_stdout: false) end, opts)
  end

  @doc "Builds the CLI argv for a structured completion."
  @spec build_args(String.t(), map(), keyword()) :: [String.t()]
  def build_args(prompt, schema, opts) do
    ["-p", prompt, "--output-format", "json", "--json-schema", Jason.encode!(schema)] ++
      model_args(opts) ++ tool_args(opts)
  end

  @doc """
  Parses the `claude --output-format json` envelope.

  Returns the structured output **and what the call cost**. The envelope has
  carried `usage` and `total_cost_usd` all along and this function used to
  drop them on the floor, which is why the app could spend all afternoon and
  not say how much.
  """
  @spec parse_output(String.t()) :: {:ok, map(), Usage.t()} | {:error, Error.t()}
  def parse_output(output) do
    case Jason.decode(output) do
      {:ok, %{"is_error" => true} = envelope} ->
        {:error, ai_error("A IA retornou erro.", %{result: envelope["result"]})}

      {:ok, %{"structured_output" => structured} = envelope} when is_map(structured) ->
        {:ok, structured, Usage.from_envelope(envelope)}

      {:ok, envelope} ->
        {:error,
         ai_error("A IA respondeu sem saída estruturada.", %{
           envelope: Map.take(envelope, ["subtype", "result"])
         })}

      {:error, _decode_error} ->
        {:error,
         ai_error("Não consegui ler a resposta da IA.", %{output: String.slice(output, 0, 200)})}
    end
  end

  defp run(fun, opts) do
    case Cli.run(fun, timeout(opts)) do
      {:ok, {output, 0}} ->
        parse_output(output)

      {:ok, {output, code}} ->
        {:error,
         ai_error("O `claude` saiu com código #{code}.", %{output: String.slice(output, 0, 500)})}

      {:error, {:exit, reason}} ->
        {:error, ai_error("O `claude` morreu.", %{reason: inspect(reason)})}

      {:error, :timeout} ->
        {:error,
         Error.new(:ai_timeout, "A IA não respondeu a tempo.", %{timeout_ms: timeout(opts)})}
    end
  end

  defp ai_error(message, details), do: Error.new(:ai_unavailable, message, details)

  defp tool_args(opts) do
    case opts[:allowed_tools] do
      [_first | _rest] = tools -> ["--allowedTools", Enum.join(tools, ",")]
      _none -> []
    end
  end

  defp model_args(opts) do
    case opts[:model] do
      model when is_binary(model) -> ["--model", model]
      _none -> []
    end
  end

  defp executable, do: config()[:executable] || "claude"

  defp timeout(opts), do: opts[:timeout_ms] || config()[:timeout_ms] || @default_timeout_ms

  defp config, do: Application.get_env(:deckex, __MODULE__, [])
end
