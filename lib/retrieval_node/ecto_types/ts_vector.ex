defmodule RetrievalNode.EctoTypes.TsVector do
  @moduledoc """
  Load-only Ecto type for the DB-generated `tsv` tsvector column on `chunks`.

  The column is `GENERATED ALWAYS AS (...) STORED`, so it is never written from
  application code — only read. Postgrex already decodes `tsvector` natively into
  a list of `Postgrex.Lexeme` structs (its `tsvector` extension is bundled into
  `RetrievalNode.PostgrexTypes` via `Ecto.Adapters.Postgres.extensions/0`), so
  this type is a thin pass-through that lets the schema expose the column
  read-only for introspection/debugging. On the schema the field is declared
  `writable: :never, load_in_query: false`, so it is never written (`dump/1` is
  never exercised in practice) and stays off the default select — an explicit
  `select: [c.tsv]` still loads it.
  """
  use Ecto.Type

  @impl true
  def type, do: :tsvector

  @impl true
  def cast(value), do: {:ok, value}

  @impl true
  def load(value), do: {:ok, value}

  @impl true
  def dump(value), do: {:ok, value}

  @impl true
  def embed_as(_format), do: :self

  @impl true
  def equal?(a, b), do: a == b
end
