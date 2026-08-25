defmodule Kanta.Test.ExitingLocale do
  @moduledoc """
  A locale value whose stringification exits, used to force an exit-class
  failure inside the real extraction path.

  Database failures reach us as exceptions most of the time, but not always:
  `DBConnection.Holder.checkout/3` exits when the pool is dead or goes down
  while a checkout is queued, and nothing in `ecto_sql` converts that into an
  exception. `rescue` does not catch exits, so extraction has to guard against
  both classes.

  The sandbox pool converts every failure it can produce into an exception, so
  an exit cannot be provoked through the database in tests. Putting this struct
  in `:allowed_locales` exits from inside `MessagesExtractor.call/0` instead,
  which is the same place a checkout exit would surface.
  """

  defstruct []

  defimpl String.Chars do
    def to_string(_exiting_locale), do: exit(:noproc)
  end
end
