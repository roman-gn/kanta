defmodule Kanta.PoFiles.MessagesExtractorAgentTest do
  @moduledoc """
  Regression tests for boot-time message extraction.

  Extraction runs database round-trips for every gettext message. While it lived
  in `init/1`, a single failed checkout raised there, which failed the host
  application's start and took the whole VM down with it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanta.PoFiles.MessagesExtractorAgent
  alias Kanta.PoFiles.Services.StaleDetection
  alias Kanta.Test.ExitingLocale

  describe "init/1" do
    test "returns immediately, deferring every database call to the continue" do
      # This test checks out no sandbox connection, so a query here would fail.
      assert {:ok, %{stale_detection_result: nil}, {:continue, :extract_messages}} =
               MessagesExtractorAgent.init([])
    end
  end

  describe "extraction" do
    setup :checkout_database

    test "stores the stale detection result" do
      pid = start_agent()

      assert %{stale_detection_result: %StaleDetection.Result{}, extraction_attempts: 0} =
               :sys.get_state(pid)
    end

    test "starts and stays alive when extraction raises" do
      break_extraction("en")

      {pid, log} = with_log(fn -> start_agent() end)

      assert Process.alive?(pid)
      assert log =~ "Message extraction failed"
      assert log =~ "FunctionClauseError"
    end

    # `rescue` only catches the :error class. DBConnection exits when the pool is
    # dead or goes down while a checkout is queued, and an exit escaping the
    # continue would kill the agent, exhaust the supervisor's restart budget and
    # relocate the VM crash from boot to runtime.
    test "starts and stays alive when extraction exits" do
      break_extraction([%ExitingLocale{}])

      {pid, log} = with_log(fn -> start_agent() end)

      assert Process.alive?(pid)
      assert log =~ "Message extraction failed"
      # Proves the exit class was caught, not merely an exception.
      assert log =~ "** (exit)"
      assert %{stale_detection_result: nil, extraction_attempts: 1} = :sys.get_state(pid)
    end

    test "keeps a nil result and counts the attempt when extraction raises" do
      break_extraction("en")

      {pid, _log} = with_log(fn -> start_agent() end)

      assert %{stale_detection_result: nil, extraction_attempts: 1} = :sys.get_state(pid)
    end

    test "backs off further when a retry fails again" do
      break_extraction("en")

      {pid, _log} = with_log(fn -> start_agent() end)
      log = capture_log(fn -> retry(pid) end)

      assert Process.alive?(pid)
      assert log =~ "Message extraction failed"
      assert %{stale_detection_result: nil, extraction_attempts: 2} = :sys.get_state(pid)
    end

    test "extracts on a retry once extraction can succeed again" do
      break_extraction("en")

      {pid, _log} = with_log(fn -> start_agent() end)

      repair_extraction()
      retry(pid)

      assert %{stale_detection_result: %StaleDetection.Result{}, extraction_attempts: 0} =
               :sys.get_state(pid)
    end

    # Defining any handle_info/2 clause replaces the catch-all GenServer injects,
    # so without one of our own a stray message would kill the agent.
    test "ignores stray messages" do
      pid = start_agent()

      send(pid, :some_stray_message)
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})

      assert Process.alive?(pid)

      assert %{stale_detection_result: %StaleDetection.Result{}, extraction_attempts: 0} =
               :sys.get_state(pid)
    end

    test "skips extraction with a single log when the database is not migrated" do
      Kanta.Test.Repo.query!("COMMENT ON TABLE kanta_messages IS '2'")

      {pid, log} = with_log(fn -> start_agent() end)

      assert log =~ "migration"
      # An out-of-date migration is a settled state, not a transient failure, so
      # it must not spin on the retry timer.
      assert %{stale_detection_result: nil, extraction_attempts: 0} = :sys.get_state(pid)
    end
  end

  describe "extraction when the database is unreachable" do
    # No sandbox connection is checked out here, so every query the agent makes
    # fails - the pool contention that crashed production, reproduced.

    test "retries instead of silently settling for no translations" do
      {pid, log} = with_log(fn -> start_agent() end)

      assert Process.alive?(pid)
      assert log =~ "Message extraction failed"

      # `migrated_version/1` reports 0 for a failed query, which is indistinguishable
      # from an un-migrated database. Settling there would leave the host app
      # without translations until someone restarted it.
      assert %{stale_detection_result: nil, extraction_attempts: 1} = :sys.get_state(pid)
    end
  end

  defp checkout_database(_context) do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Kanta.Test.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    :ok
  end

  # The agent registers itself under its module name and one instance already
  # runs for the whole suite (see test/test_helper.exs), so tests start unnamed
  # instances directly from the callback module.
  defp start_agent do
    {:ok, pid} = GenServer.start_link(MessagesExtractorAgent, [])
    on_exit(fn -> Process.exit(pid, :kill) end)

    # `:sys.get_state/1` is only answered once the continue has run, which keeps
    # the assertions deterministic without sleeping.
    _ = :sys.get_state(pid)

    pid
  end

  # `:allowed_locales` is documented as a list, so a bare string raises a
  # FunctionClauseError deep inside extraction, after the availability check has
  # already passed. A list holding an `ExitingLocale` exits from the same place.
  defp break_extraction(allowed_locales) do
    previous = Application.fetch_env(:kanta, :allowed_locales)
    Application.put_env(:kanta, :allowed_locales, allowed_locales)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanta, :allowed_locales, value)
        :error -> Application.delete_env(:kanta, :allowed_locales)
      end
    end)
  end

  defp repair_extraction, do: Application.delete_env(:kanta, :allowed_locales)

  # Simulates the retry timer firing, then waits for the retry to be handled.
  defp retry(pid) do
    send(pid, :retry_extract)
    _ = :sys.get_state(pid)

    :ok
  end
end
