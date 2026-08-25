defmodule Kanta.MigrationVersionChecker do
  @moduledoc """
  GenServer responsible for checking if a new migration version is available for Kanta.

  This module runs a version check when started to compare the current database migration
  version against the latest available version. If a newer version is available, it displays
  a formatted warning message in the console with:

  - Current and latest version numbers
  - Step-by-step instructions for updating
  - Commands to generate and run the required migrations

  The checker supports both PostgreSQL and SQLite3 databases and automatically detects
  which adapter is being used.
  """

  use GenServer

  require Logger

  @colors [
    warning: :yellow,
    highlight: :cyan,
    brand: :magenta,
    reset: :reset
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # This check queries the database, so it must not run here: failing in
    # `init/1` fails the host application's start and brings the whole VM down
    # with it. The check is advisory console output — never worth an outage.
    {:ok, %{}, {:continue, :check_version}}
  end

  @impl true
  def handle_continue(:check_version, state) do
    check_version()

    {:noreply, state}
  catch
    kind, reason ->
      Logger.warning(
        "[Kanta] Migration version check failed\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:noreply, state}
  end

  defp check_version do
    migrator =
      case Kanta.Repo.get_adapter_name() do
        :postgres -> Kanta.Migrations.Postgresql
        :sqlite -> Kanta.Migrations.SQLite3
      end

    latest_version = migrator.current_version()
    migrated = migrator.migrated_version(%{repo: Kanta.Repo.get_repo()})

    if migrated < latest_version do
      warning_message = """
      #{colorize("⚠️  [Kanta Migration Alert]", @colors[:warning])}
      #{colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━", @colors[:brand])}

      A new version of Kanta migrations is available for your database!

      Current version: #{colorize(to_string(migrated), @colors[:highlight])}
      Latest version: #{colorize(to_string(latest_version), @colors[:highlight])}

      To ensure optimal performance and functionality, please update your database schema.

      📝 Here's what you need to do:

      1. Generate a new migration:
         #{colorize("$ mix ecto.gen.migration update_kanta_migrations", @colors[:brand])}

      2. Add the following to your migration file:
         #{colorize("def up do", @colors[:highlight])}
           #{colorize("Kanta.Migration.up(version: #{latest_version})", @colors[:highlight])}
         #{colorize("end", @colors[:highlight])}

         #{colorize("def down do", @colors[:highlight])}
           #{colorize("Kanta.Migration.down(version: #{latest_version})", @colors[:highlight])}
         #{colorize("end", @colors[:highlight])}

      3. Run the migration:
         #{colorize("$ mix ecto.migrate", @colors[:brand])}

      📚 For more details, visit the Kanta documentation.
      #{colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━", @colors[:brand])}
      """

      IO.puts(warning_message)
    end
  end

  defp colorize(text, color) do
    IO.ANSI.format([color, text, @colors[:reset]])
    |> IO.chardata_to_string()
  end
end
