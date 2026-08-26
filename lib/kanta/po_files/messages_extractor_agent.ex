defmodule Kanta.PoFiles.MessagesExtractorAgent do
  @moduledoc """
  GenServer responsible for extracting messages and translations from .po files
  """

  use GenServer

  require Logger

  alias Kanta.PoFiles.MessagesExtractor
  alias Kanta.PoFiles.Services.StaleDetection

  @initial_retry_delay :timer.seconds(5)
  @max_retry_delay :timer.seconds(60)
  # Caps the exponent as well as the delay, so an extraction that keeps failing
  # for weeks cannot grow the backoff into a bignum.
  @max_backoff_doublings 4

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Extraction queries the database for every message, so it must not run
    # here: failing in `init/1` fails the host application's start and brings
    # the whole VM down with it.
    {:ok, %{stale_detection_result: nil, extraction_attempts: 0}, {:continue, :extract_messages}}
  end

  @impl true
  def handle_continue(:extract_messages, state) do
    if Kanta.boot_jobs_enabled?() do
      {:noreply, extract_messages(state)}
    else
      Logger.debug("[Kanta] Skipping message extraction: :boot_jobs is disabled.")

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_extract, state) do
    {:noreply, extract_messages(state)}
  end

  # Defining a clause above replaces the catch-all GenServer injects, and a stray
  # message must not kill the agent.
  def handle_info(_message, state) do
    {:noreply, state}
  end

  @doc """
  Gets system-wide stale message IDs.

  ## Returns

    * `MapSet.t()` - Set of stale message IDs, or empty MapSet

  ## Examples

      iex> MessagesExtractorAgent.get_stale_message_ids()
      #MapSet<[1, 2, 3]>

  """
  def get_stale_detection_result(recalculate \\ false) do
    GenServer.call(__MODULE__, {:get_stale_detection_result, recalculate})
  end

  @impl true
  def handle_call({:get_stale_detection_result, false}, _from, state) do
    {:reply, state.stale_detection_result, state}
  end

  def handle_call({:get_stale_detection_result, true}, _from, state) do
    {:ok, %StaleDetection.Result{} = result} = StaleDetection.call()

    {:reply, result, %{state | stale_detection_result: result}}
  end

  # Extraction is best-effort: a database that is briefly unavailable must never
  # take the process (and with it the host application) down, so failures are
  # logged and retried with an exponential backoff instead. Both failure classes
  # have to be caught — DBConnection raises for most failures, but exits when the
  # pool is dead or goes down while a checkout is queued.
  defp extract_messages(state) do
    # `migrated_version/1` answers 0 when its own query fails, which is
    # indistinguishable from a database nobody has migrated yet. Probing the
    # connection first keeps an unreachable database on the retry path instead of
    # quietly settling for no translations until someone restarts the host app.
    Kanta.Repo.get_repo().query!("SELECT 1")

    if message_extractor_available?() do
      {:ok, _messages} = MessagesExtractor.call()

      # Detect stale translations system-wide with fuzzy matching
      {:ok, %StaleDetection.Result{} = result} = StaleDetection.call()

      %{state | stale_detection_result: result, extraction_attempts: 0}
    else
      # Settled state rather than a failure, so it is logged once and not retried.
      Logger.warning("[Kanta] Skipping message extraction: Kanta migrations are out of date.")

      state
    end
  catch
    kind, reason ->
      delay =
        min(
          @initial_retry_delay * 2 ** min(state.extraction_attempts, @max_backoff_doublings),
          @max_retry_delay
        )

      Logger.warning(
        "[Kanta] Message extraction failed, retrying in #{delay}ms\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      Process.send_after(self(), :retry_extract, delay)

      %{state | extraction_attempts: state.extraction_attempts + 1}
  end

  defp message_extractor_available? do
    # Message extractor requires columns added in version 3 of Postgres migration and version 2 of SQLite migration.
    migrator =
      case Kanta.Repo.get_adapter_name() do
        :postgres -> Kanta.Migrations.Postgresql
        :sqlite -> Kanta.Migrations.SQLite3
      end

    migrated_version = migrator.migrated_version(%{repo: Kanta.Repo.get_repo()})

    case Kanta.Repo.get_adapter_name() do
      :postgres -> migrated_version >= 3
      :sqlite -> migrated_version >= 2
    end
  end
end
