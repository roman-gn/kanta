defmodule Kanta.BootJobsTest do
  @moduledoc """
  Kanta's two boot processes query the database and then live for the lifetime of
  the application. Under `Ecto.Adapters.SQL.Sandbox` in auto mode that holds a
  connection each until the process dies, so a host application's test run hits
  the sandbox's `:ownership_timeout` and gets its connections reaped mid-suite.

  Such a host can opt out of the boot work entirely and fall back to
  `Kanta.Backend`'s po file translations.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Kanta.MigrationVersionChecker
  alias Kanta.PoFiles.MessagesExtractorAgent
  alias Kanta.PoFiles.Services.StaleDetection
  alias Kanta.Translations
  alias Kanta.Translations.Message

  @locale "pl"

  setup do
    Application.put_env(:kanta, :boot_jobs, false)
    Kanta.Cache.delete_all!()

    on_exit(fn ->
      Application.delete_env(:kanta, :boot_jobs)
      Kanta.Cache.delete_all!()
    end)

    :ok
  end

  describe "with no database connection checked out" do
    # Nothing is checked out here on purpose: any query either process made would
    # fail, so passing quietly is what proves neither one queried at all. That is
    # the whole point of the flag — a process that never queries is never
    # allocated a connection to reap.

    test "the extractor agent makes no database call" do
      {pid, log} = with_log(fn -> start_agent() end)

      assert Process.alive?(pid)
      assert %{stale_detection_result: nil, extraction_attempts: 0} = :sys.get_state(pid)

      # A query would have failed, been logged and left a retry timer behind.
      refute log =~ "Message extraction failed"
      refute log =~ "Skipping message extraction"
    end

    test "the version checker makes no database call" do
      {pid, output} = with_io(fn -> start_checker() end)

      assert Process.alive?(pid)
      assert :sys.get_state(pid) == %{}
      refute output =~ "Kanta Migration Alert"
    end
  end

  describe "with a database and po files available" do
    setup :checkout_database
    setup :write_po_file

    test "the extractor agent stores nothing" do
      pid = start_agent()

      assert %{stale_detection_result: nil, extraction_attempts: 0} = :sys.get_state(pid)

      assert {:error, :locale, :not_found} =
               Translations.get_locale(filter: [iso639_code: @locale])

      assert Kanta.Test.Repo.aggregate(Message, :count) == 0
    end

    # Disabling the boot work must not disable Kanta itself: an admin asking for a
    # recalculation in the UI is an explicit request, not startup work.
    test "an explicitly requested stale detection still runs" do
      assert %StaleDetection.Result{} = MessagesExtractorAgent.get_stale_detection_result(true)
    end
  end

  # The same fixture as above, to show the flag is the only difference.
  describe "with boot jobs left enabled" do
    setup :checkout_database
    setup :write_po_file

    setup do
      Application.put_env(:kanta, :boot_jobs, true)

      :ok
    end

    test "the extractor agent extracts as it always has" do
      pid = start_agent()

      assert %{stale_detection_result: %StaleDetection.Result{}, extraction_attempts: 0} =
               :sys.get_state(pid)

      assert {:ok, _locale} = Translations.get_locale(filter: [iso639_code: @locale])
      assert Kanta.Test.Repo.aggregate(Message, :count) == 1
    end
  end

  defp checkout_database(_context) do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Kanta.Test.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    :ok
  end

  # Both processes register under their module name and one of each already runs
  # for the whole suite (see test/test_helper.exs), so tests start unnamed
  # instances directly from the callback modules.
  defp start_agent, do: start_process(MessagesExtractorAgent)
  defp start_checker, do: start_process(MigrationVersionChecker)

  defp start_process(module) do
    {:ok, pid} = GenServer.start_link(module, [])
    on_exit(fn -> Process.exit(pid, :kill) end)

    # `:sys.get_state/1` is only answered once the continue has run, which keeps
    # the assertions deterministic without sleeping.
    _ = :sys.get_state(pid)

    pid
  end

  # Gives the extraction something to find, so that finding nothing in the
  # database afterwards means it never ran.
  defp write_po_file(_context) do
    gettext_path = :kanta |> :code.priv_dir() |> to_string() |> Path.join("gettext")
    locale_path = Path.join(gettext_path, @locale)

    File.mkdir_p!(Path.join(locale_path, "LC_MESSAGES"))

    File.write!(Path.join([locale_path, "LC_MESSAGES", "default.po"]), """
    msgid ""
    msgstr ""
    "Language: #{@locale}\\n"

    msgid "a message"
    msgstr "wiadomosc"
    """)

    on_exit(fn ->
      File.rm_rf!(locale_path)
      # Only removes the gettext directory if this test created it.
      File.rmdir(gettext_path)
    end)

    :ok
  end
end
