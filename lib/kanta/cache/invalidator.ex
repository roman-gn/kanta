defmodule Kanta.Cache.Invalidator do
  @moduledoc """
  Propagates `Kanta.Cache` invalidations across a cluster in real time.

  `Kanta.Cache` uses a node-local adapter (`Nebulex.Adapters.Local`) so reads
  never make cross-node calls. To keep edits visible everywhere, each node runs
  an `Invalidator` subscribed to the configured `Phoenix.PubSub`. When a
  translation/message is created, updated or deleted, the originating node
  broadcasts an invalidation (`Kanta.Cache.broadcast_invalidate/1` /
  `broadcast_invalidate_all/0`); every *other* node clears the affected entry
  from its local cache, so the change shows up immediately — no pod restarts,
  no read-path RPC.

  Enabled only when `config :kanta, :pubsub, MyApp.PubSub` is set; otherwise this
  process does not start and Kanta keeps its single-node / local-only behaviour.
  """

  use GenServer

  alias Kanta.Cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    case Cache.pubsub_server() do
      nil ->
        :ignore

      server ->
        :ok = Phoenix.PubSub.subscribe(server, Cache.invalidation_topic())
        {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_info({:invalidate, key, origin}, state) do
    if origin != node() do
      Cache.delete!(key)
    end

    {:noreply, state}
  end

  def handle_info({:invalidate_all, origin}, state) do
    if origin != node() do
      Cache.delete_all!()
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
