defmodule Kanta.MigrationVersionCheckerTest do
  @moduledoc """
  The version checker starts one child before the messages extractor and had the
  same VM-fatal shape: a synchronous database call in `init/1`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kanta.MigrationVersionChecker

  describe "init/1" do
    test "returns immediately, deferring the database call to the continue" do
      # This test checks out no sandbox connection, so a query here would fail.
      assert {:ok, %{}, {:continue, :check_version}} = MigrationVersionChecker.init([])
    end
  end

  test "starts and stays alive when the database is unreachable" do
    # No sandbox connection is checked out, so the check cannot query. It reads an
    # unreachable database as version 0 and prints its migration banner, which is
    # captured here to keep the suite quiet.
    {pid, output} =
      with_io(fn ->
        {:ok, pid} = GenServer.start_link(MigrationVersionChecker, [])
        _ = :sys.get_state(pid)

        pid
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert Process.alive?(pid)
    assert :sys.get_state(pid) == %{}
    assert output =~ "Kanta Migration Alert"
  end
end
