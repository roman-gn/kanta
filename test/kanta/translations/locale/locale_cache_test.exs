defmodule Kanta.Translations.Locale.LocaleCacheTest do
  @moduledoc """
  Regression tests for a locale left stale in the cache.

  Extracting into an empty database creates the locale from the first singular
  message, with no plurals header. The next singular message read-through-caches
  that row, and the first plural message updates the header in the database only
  — so the cache kept serving a locale whose `plurals_header` was nil, and
  `Expo.PluralForms.parse/1` raised out of every plural lookup for that locale.
  """

  use Kanta.Test.DataCase, async: false

  alias Kanta.Backend.Adapter.CachedDB
  alias Kanta.PoFiles.MessagesExtractor
  alias Kanta.Translations

  @locale "pl"
  @msgid_plural "%{count} apples"
  @plurals_header "nplurals=2; plural=(n != 1);"

  setup do
    Kanta.Cache.delete_all!()

    on_exit(fn ->
      Kanta.Cache.delete_all!()
    end)

    :ok
  end

  describe "extraction into an empty database" do
    setup :write_po_file

    test "leaves the cached locale holding the plurals header from the po file" do
      {:ok, _messages} = MessagesExtractor.call()

      # The cached read is the one that went stale; the database row was correct.
      assert {:ok, locale} = Translations.get_locale(filter: [iso639_code: @locale])
      assert locale.plurals_header
    end

    # A nil plurals_header raised a FunctionClauseError out of every ngettext call
    # for this locale, instead of falling back to gettext's own default.
    test "leaves an untranslated plural falling back rather than raising" do
      {:ok, _messages} = MessagesExtractor.call()

      # Extraction records the po file's text as `original_text`, so nothing is
      # translated until someone translates it in Kanta.
      assert {:error, :not_found} = lngettext(2)
    end

    test "resolves a plural through the extracted plurals header" do
      {:ok, _messages} = MessagesExtractor.call()

      # Polish takes this form for 2, which is only reachable by parsing the
      # header the extraction stored.
      translate_plural(1, "%{count} jablka")

      assert {:ok, "2 jablka"} = lngettext(2)
    end
  end

  describe "update_locale/3" do
    test "refreshes the locale cached by iso639 code" do
      locale = create_locale()
      {:ok, cached} = Translations.get_locale(filter: [iso639_code: @locale])
      assert is_nil(cached.plurals_header)

      {:ok, _updated} = Translations.update_locale(locale, %{plurals_header: @plurals_header})

      assert {:ok, %{plurals_header: @plurals_header}} =
               Translations.get_locale(filter: [iso639_code: @locale])
    end

    test "refreshes the locale cached by id" do
      locale = create_locale()
      {:ok, cached} = Translations.get_locale(filter: [id: locale.id])
      assert is_nil(cached.plurals_header)

      {:ok, _updated} = Translations.update_locale(locale, %{plurals_header: @plurals_header})

      assert {:ok, %{plurals_header: @plurals_header}} =
               Translations.get_locale(filter: [id: locale.id])
    end
  end

  defp lngettext(count) do
    CachedDB.lngettext(@locale, "default", "default", "one apple", @msgid_plural, count, %{})
  end

  defp translate_plural(nplural_index, translated_text) do
    {:ok, message} = Translations.get_message(filter: [msgid: @msgid_plural])
    {:ok, locale} = Translations.get_locale(filter: [iso639_code: @locale])

    {:ok, translation} =
      Translations.get_plural_translation(
        filter: [message_id: message.id, locale_id: locale.id, nplural_index: nplural_index]
      )

    {:ok, _translation} =
      Translations.update_plural_translation(translation, %{translated_text: translated_text})
  end

  defp create_locale do
    {:ok, locale} =
      Translations.create_locale(%{
        iso639_code: @locale,
        name: "Polish",
        native_name: "Polski"
      })

    locale
  end

  # `MessagesExtractor` reads the host application's own gettext directory, so the
  # only way to drive it is to put a file there. The messages are ordered the way
  # the incident needs: a singular message creates the locale, a second one caches
  # it, and only then does a plural message supply the header.
  defp write_po_file(_context) do
    locale_path = Path.join(gettext_path(), @locale)
    messages_path = Path.join(locale_path, "LC_MESSAGES")

    File.mkdir_p!(messages_path)

    File.write!(Path.join(messages_path, "default.po"), """
    msgid ""
    msgstr ""
    "Language: #{@locale}\\n"
    "Plural-Forms: #{@plurals_header}\\n"

    msgid "first singular"
    msgstr "pierwszy"

    msgid "second singular"
    msgstr "drugi"

    msgid "one apple"
    msgid_plural "#{@msgid_plural}"
    msgstr[0] "1 jablko"
    msgstr[1] "%{count} jablka"
    """)

    on_exit(fn ->
      File.rm_rf!(locale_path)
      # Only removes the directory this test created it for; a non-empty gettext
      # directory is left alone.
      File.rmdir(gettext_path())
    end)

    :ok
  end

  defp gettext_path do
    :kanta
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("gettext")
  end
end
