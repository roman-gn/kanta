defmodule Kanta.Translations.Locale.Services.CreateLocaleFromIsoCode do
  @moduledoc """
  Service for mapping locale iso639 code to the Kanta locale
  """

  alias Kanta.Repo

  alias Kanta.Translations.Locale

  alias Kanta.Translations.Locale.Utils.LocaleCodeMapper

  # A locale row must never exist without its plurals header: the singular
  # extractor creates locales before any plural message has been seen, and a
  # header-less row makes every plural lookup fail until a plural message for
  # that locale is extracted. Derive it from the locale code (the same source
  # `MessagesExtractor.get_plurals_header/2` falls back to), keeping the
  # legacy attrs when Expo knows nothing about the code.
  def call(iso_code, nil) do
    case Expo.PluralForms.plural_form(iso_code) do
      {:ok, plural_forms} -> call(iso_code, Expo.PluralForms.to_string(plural_forms))
      :error -> insert(mapped_attrs(iso_code))
    end
  end

  def call(iso_code, plurals_header), do: insert(mapped_attrs(iso_code, plurals_header))

  defp insert(attrs) do
    %Locale{}
    |> Locale.changeset(attrs)
    |> Repo.get_repo().insert()
  end

  defp mapped_attrs(iso_code) do
    %{
      "iso639_code" => iso_code,
      "name" => LocaleCodeMapper.get_name(iso_code),
      "native_name" => LocaleCodeMapper.get_native_name(iso_code),
      "family" => LocaleCodeMapper.get_family(iso_code),
      "wiki_url" => LocaleCodeMapper.get_wiki_url(iso_code),
      "colors" => LocaleCodeMapper.get_colors(iso_code)
    }
  end

  defp mapped_attrs(iso_code, plurals_header) do
    %{
      "iso639_code" => iso_code,
      "name" => LocaleCodeMapper.get_name(iso_code),
      "native_name" => LocaleCodeMapper.get_native_name(iso_code),
      "family" => LocaleCodeMapper.get_family(iso_code),
      "wiki_url" => LocaleCodeMapper.get_wiki_url(iso_code),
      "colors" => LocaleCodeMapper.get_colors(iso_code),
      "plurals_header" => plurals_header
    }
  end
end
