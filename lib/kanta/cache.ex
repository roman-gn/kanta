defmodule Kanta.Cache do
  @moduledoc """
  Kanta Cache for minimalizing calls to DB
  """

  use Nebulex.Cache,
    otp_app: :kanta,
    adapter: Nebulex.Adapters.Local

  @invalidation_topic "kanta:applicationcache_invalidation"

  @doc false
  def pubsub_server, do: Application.get_env(:kanta, :pubsub)

  @doc false
  def invalidation_topic, do: @invalidation_topic

  @doc """
  Invalidate `key` on the OTHER cluster nodes so a translation/message change
  propagates in real time. The local node is left untouched (it already holds the
  fresh value). No-op unless `config :kanta, :pubsub, MyApp.PubSub` is set — in
  which case Kanta keeps its single-node, local-only behaviour.

  See `Kanta.Cache.Invalidator`.
  """
  def broadcast_invalidate(key) do
    if server = pubsub_server() do
      Phoenix.PubSub.broadcast(server, @invalidation_topic, {:invalidate, key, node()})
    end

    :ok
  end

  @doc "Invalidate the whole cache on the OTHER cluster nodes."
  def broadcast_invalidate_all do
    if server = pubsub_server() do
      Phoenix.PubSub.broadcast(server, @invalidation_topic, {:invalidate_all, node()})
    end

    :ok
  end

  def generate_cache_key(prefix, params) do
    Enum.reduce(params, prefix, fn {key, value}, acc ->
      case value do
        val when is_binary(val) ->
          acc <> "_" <> to_string(key) <> "_" <> URI.encode_query(val)

        val when is_list(val) ->
          # this old way is just broken for preloads lists
          # encoded_list = (Enum.into(val, %{}) |> URI.encode_query())
          # the new way is robust and reversible
          encoded_list =
            val
            |> :erlang.term_to_binary()
            |> URI.encode()
            |> then(&%{encoded_params: &1})
            |> URI.encode_query()

          acc <> "_" <> to_string(key) <> "_" <> encoded_list

        _val ->
          acc
      end
    end)
  end
end
