defmodule RetrievalNode.Chunking.LineGraphImpl do
  @moduledoc """
  Test-only NIF-free `Chunking` impl: one chunk per file, with an entity (kind
  `:function`) for every `def NAME` line. Lets owner-level graph tests drive
  many differently-shaped files through the real pipeline without tree-sitter.
  """
  @behaviour RetrievalNode.Chunking

  @impl true
  def chunk(source, _language), do: {:ok, [chunk(source)]}

  @impl true
  def allowed_languages, do: []

  @impl true
  def chunk_with_graph(source, _language) do
    entities =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        case Regex.run(~r/^def (\w+)/, line) do
          [_, name] -> [%{qualified_name: name, kind: :function, line: n}]
          nil -> []
        end
      end)

    {:ok, %{chunks: [chunk(source)], entities: entities, references: []}}
  end

  defp chunk(source) do
    %{
      text: source,
      breadcrumb: "file",
      start_line: 1,
      end_line: length(String.split(source, "\n")),
      kind: "file",
      parse_status: :ok
    }
  end
end
