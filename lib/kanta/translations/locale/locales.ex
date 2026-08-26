defmodule Kanta.Translations.Locales do
  @moduledoc """
  Locales Kanta subcontext
  """

  alias Kanta.Cache
  alias Kanta.Repo

  alias Kanta.Translations.Locale
  alias Kanta.Translations.Locale.Finders.{GetLocale, ListLocales}

  # The fields `GetLocale` is queried by, and so the ones it caches a locale under.
  @cached_lookups [:iso639_code, :id]

  def list_locales(params \\ []) do
    ListLocales.find(params)
  end

  def get_locale(params \\ []) do
    GetLocale.find(params)
  end

  def create_locale(attrs, opts \\ []) do
    %Locale{}
    |> Locale.changeset(attrs)
    |> Repo.get_repo().insert(opts)
    |> cache_locale()
  end

  def update_locale(locale, attrs \\ %{}, opts \\ []) do
    Locale.changeset(locale, attrs)
    |> Repo.get_repo().update(opts)
    |> cache_locale()
  end

  # A write has to refresh every key the locale is cached under, or a reader keeps
  # serving its stale copy — which is how a locale created without a plurals header
  # outlived the update that gave it one, raising out of every plural lookup.
  defp cache_locale({:ok, %Locale{} = locale}) do
    Enum.each(@cached_lookups, fn field ->
      cache_key = Cache.generate_cache_key("locale", filter: [{field, Map.fetch!(locale, field)}])

      Cache.put!(cache_key, locale)
      Cache.broadcast_invalidate(cache_key)
    end)

    {:ok, locale}
  end

  defp cache_locale(error), do: error
end
