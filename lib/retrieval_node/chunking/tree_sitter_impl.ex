defmodule RetrievalNode.Chunking.TreeSitterImpl do
  @moduledoc """
  AST-boundary chunking via the `tree_sitter_language_pack` NIF.

  Pre-flight guards (size cap, binary/null-byte detection, language allowlist)
  reject the inputs most likely to cause pathological parse runtime *before* they
  reach the NIF. The parse then runs inside a supervised `Task`
  (`async_nolink` + `Task.yield` + `Task.shutdown(:brutal_kill)`) so a hang
  degrades to `{:error, :chunk_timeout}` and an abnormal exit to
  `{:error, {:chunk_crashed, reason}}` — never a crash of the calling process.

  Honesty about the limits (see `design-otp.md` §3.3): the parse NIF is **not**
  dirty-scheduled (verified in the crate source), so a merely-slow parse still
  costs regular-scheduler fairness, and no in-VM guard catches a C-level segfault
  — that's the peer-node escape hatch's job, deferred to v1.1.

  v1 covers the mainstream code languages; Elixir/HEEx/EEx fall through to the
  heuristic chunker until the native-AST Elixir path lands (fast-follow).
  """

  @behaviour RetrievalNode.Chunking

  alias TreeSitterLanguagePack, as: TS

  @max_bytes Application.compile_env(:retrieval_node, [:chunking, :max_bytes], 2_000_000)
  @call_timeout_ms Application.compile_env(:retrieval_node, [:chunking, :call_timeout_ms], 5_000)
  @supervisor RetrievalNode.ChunkTaskSupervisor

  @allowed_languages ~w(python javascript typescript go rust ruby java)

  # Node kinds that mark a chunk boundary, per language. A node is emitted as a
  # chunk only if it has no chunkable descendants (leaf-most def); a container
  # (e.g. a class) yields its members instead, with the container name in the
  # breadcrumb — so methods are chunks scoped as "Class > method".
  @chunk_kinds %{
    "python" => ~w(function_definition class_definition),
    "javascript" =>
      ~w(function_declaration generator_function_declaration class_declaration method_definition),
    "typescript" =>
      ~w(function_declaration generator_function_declaration class_declaration method_definition interface_declaration type_alias_declaration enum_declaration),
    "go" => ~w(function_declaration method_declaration type_declaration),
    "rust" => ~w(function_item struct_item enum_item trait_item impl_item mod_item),
    "ruby" => ~w(method singleton_method class module),
    "java" =>
      ~w(method_declaration constructor_declaration class_declaration interface_declaration enum_declaration record_declaration)
  }

  @impl true
  def allowed_languages, do: @allowed_languages

  @impl true
  def chunk(source, language) when is_binary(source) do
    with :ok <- check_size(source),
         :ok <- check_binary_content(source),
         :ok <- check_language_allowlist(language) do
      guarded(fn -> parse_to_chunks(source, language) end)
    end
  end

  @doc """
  Run `fun` (a 0-arity function returning `{:ok, chunks} | {:error, reason}`) in a
  supervised, timeout-bounded, crash-isolated Task.

  `async_nolink` is the essential detail: an abnormal task exit does NOT propagate
  a linked exit to the caller, so a crashing parse surfaces as
  `{:error, {:chunk_crashed, reason}}` instead of also killing the caller (e.g.
  the Oban job process). Exposed (not private) so the guard behaviour is testable
  without the NIF.
  """
  @spec guarded((-> {:ok, [map()]} | {:error, term()})) ::
          {:ok, [map()]} | {:error, :chunk_timeout | {:chunk_crashed, term()} | term()}
  def guarded(fun) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(@supervisor, fun)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, chunks}} -> {:ok, chunks}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_return, other}}
      nil -> {:error, :chunk_timeout}
      {:exit, reason} -> {:error, {:chunk_crashed, reason}}
    end
  end

  defp check_size(bin) when byte_size(bin) > @max_bytes, do: {:error, :too_large}
  defp check_size(_), do: :ok

  defp check_binary_content(bin),
    do: if(String.contains?(bin, <<0>>), do: {:error, :binary_content}, else: :ok)

  defp check_language_allowlist(lang),
    do: if(lang in @allowed_languages, do: :ok, else: {:error, :unsupported_language})

  defp parse_to_chunks(source, language) do
    parser = TS.parser_new()

    case TS.parser_set_language(parser, language) do
      {:ok, {}} ->
        root =
          parser
          |> TS.parser_parse(source)
          |> TS.tree_root_node()

        {:ok, extract(root, source, language, [])}

      {:error, reason} ->
        {:error, {:language_load, reason}}
    end
  end

  defp extract(node, source, language, scope) do
    kinds = Map.fetch!(@chunk_kinds, language)

    node
    |> named_children()
    |> Enum.flat_map(&extract_child(&1, source, language, scope, kinds))
  end

  defp extract_child(child, source, language, scope, kinds) do
    kind = TS.node_kind(child)

    if kind in kinds do
      emit_or_recurse(child, source, language, scope, kind)
    else
      # Non-chunkable wrapper (block/body/decorator): descend, keep scope.
      extract(child, source, language, scope)
    end
  end

  # A chunkable node with chunkable descendants (a container, e.g. a class) yields
  # its members; a leaf-most one is emitted as a chunk itself.
  defp emit_or_recurse(child, source, language, scope, kind) do
    child_scope = scope ++ [node_name(child, source)]

    case extract(child, source, language, child_scope) do
      [] -> [to_chunk(child, source, kind, child_scope)]
      nested -> nested
    end
  end

  defp named_children(node) do
    case TS.node_named_child_count(node) do
      0 -> []
      n -> Enum.map(0..(n - 1), &TS.node_named_child(node, &1))
    end
  end

  defp node_name(node, source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> TS.node_kind(node)
      name_node -> slice(source, name_node)
    end
  end

  defp to_chunk(node, source, kind, scope) do
    start_pos = TS.node_start_position(node)
    end_pos = TS.node_end_position(node)

    %{
      text: slice(source, node),
      breadcrumb: Enum.join(scope, " > "),
      start_line: start_pos.row + 1,
      end_line: end_pos.row + 1,
      kind: kind,
      parse_status: :ok
    }
  end

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    binary_part(source, start_byte, TS.node_end_byte(node) - start_byte)
  end
end
