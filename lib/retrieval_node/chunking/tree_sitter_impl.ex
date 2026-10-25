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

  v1 covers the mainstream code languages plus Elixir; HEEx/EEx fall through to
  the heuristic chunker until their native-AST path lands (fast-follow).

  Coverage invariant: every non-whitespace byte of a chunked file belongs to
  exactly one chunk. Definition chunks (leaf-most boundary nodes) are emitted
  as-is; the stretches between them — imports, constants, decorators, a class's
  header and fields, module-level statements, an Elixir module's `@moduledoc`/
  `use`/ExUnit `test` blocks — become `kind: "toplevel"` chunks. A container
  (a boundary node with nested boundaries) emits its nested chunks plus the
  gaps of its own byte range, scoped to the container; the root emits the
  gaps of the whole file with an empty breadcrumb. Gaps are trimmed to their
  non-whitespace extent and split at line boundaries using the heuristic
  chunker's size limits, working purely on byte offsets into the original
  source (so CRLF is preserved and `text == binary_part(source, ...)`).

  Elixir is the one language here whose grammar has no fixed boundary-kind
  set: `defmodule`/`def`/`defp`/... all parse as a bare `call` node (target:
  identifier), so `chunk_boundary?/4` special-cases it with a predicate
  (target text in `@elixir_def_forms`) instead of a kind-set lookup. The form
  set and name canonicalisation (`defdelegate`, `Elixir.Foo` -> `Foo`) match
  `Graph.Extractor.TreeSitter`, so chunk breadcrumbs agree with entity names.
  """

  @behaviour RetrievalNode.Chunking

  alias RetrievalNode.Chunking.HeuristicImpl
  alias RetrievalNode.Graph.Extractor
  alias TreeSitterLanguagePack, as: TS

  @max_bytes Application.compile_env(:retrieval_node, [:chunking, :max_bytes], 2_000_000)
  @call_timeout_ms Application.compile_env(:retrieval_node, [:chunking, :call_timeout_ms], 5_000)

  # DEPENDENCY: this named Task.Supervisor must be in the supervision tree before
  # any runtime caller invokes chunk/2 — otherwise `async_nolink` raises :noproc
  # in the caller (which guarded/1 cannot catch, since no task exists yet). Added
  # to the tree in Phase 8; until then only tests use it (via start_supervised!).
  @supervisor RetrievalNode.ChunkTaskSupervisor

  @allowed_languages ~w(python javascript typescript go rust ruby java elixir)

  # Elixir def-family forms that mark a chunk boundary when they're a `call`
  # node's target identifier. defmodule/defprotocol/defimpl are containers
  # (their do_block holds nested defs); the rest are leaf-most function chunks.
  @elixir_module_forms ~w(defmodule defprotocol defimpl)
  @elixir_function_forms ~w(def defp defmacro defmacrop defguard defguardp defdelegate)
  @elixir_def_forms @elixir_module_forms ++ @elixir_function_forms

  @toplevel_kind "toplevel"

  # Node kinds that mark a chunk boundary, per language. A node is emitted as a
  # chunk only if it has no chunkable descendants (leaf-most def); a container
  # (e.g. a class) yields its members instead, with the container name in the
  # breadcrumb — so methods are chunks scoped as "Class > method". Elixir has
  # no entry here — see `chunk_boundary?/4`.
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
    # Cheapest check first: an O(1) allowlist lookup short-circuits before the
    # O(n) binary-content scan of an up-to-2MB blob.
    with :ok <- check_language_allowlist(language, @allowed_languages),
         :ok <- check_size(source),
         :ok <- check_binary_content(source) do
      guarded(fn -> parse_to_chunks(source, language) end)
    end
  end

  @doc """
  Like `chunk/2`, plus entities/references extracted from the SAME parse (one
  parse, two consumers — see `RetrievalNode.Graph.Extractor.TreeSitter`'s
  moduledoc). Same pre-flight guards and `guarded/1` Task isolation as
  `chunk/2`; only plain maps (never NIF node refs) cross back out of the task.
  """
  @impl true
  def chunk_with_graph(source, language) when is_binary(source) do
    with :ok <- check_language_allowlist(language, @allowed_languages),
         :ok <- check_size(source),
         :ok <- check_binary_content(source) do
      guarded(fn -> parse_to_chunks_and_graph(source, language) end)
    end
  end

  @doc """
  Run `fun` (a 0-arity function returning `{:ok, result} | {:error, reason}`) in a
  supervised, timeout-bounded, crash-isolated Task.

  `async_nolink` is the essential detail: an abnormal task exit does NOT propagate
  a linked exit to the caller, so a crashing parse surfaces as
  `{:error, {:chunk_crashed, reason}}` instead of also killing the caller (e.g.
  the Oban job process). Exposed (not private) so the guard behaviour is testable
  without the NIF.
  """
  @spec guarded((-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()}
          | {:error, :chunk_timeout | :chunk_supervisor_down | {:chunk_crashed, term()} | term()}
  def guarded(fun) when is_function(fun, 0) do
    with {:ok, task} <- start_task(fun) do
      await_task(task)
    end
  end

  # If the supervisor is absent — never started, OR it dies between a check and
  # this call (the TOCTTOU race) — async_nolink exits :noproc in THIS process,
  # which await_task's task-crash isolation can't catch (no task exists yet).
  # Catch it at the source so even that case returns an error tuple, fully
  # honoring "never crash the caller".
  defp start_task(fun) do
    {:ok, Task.Supervisor.async_nolink(@supervisor, fun)}
  catch
    :exit, {:noproc, _} -> {:error, :chunk_supervisor_down}
  end

  defp await_task(task) do
    # NOTE: the `yield || shutdown` race is handled by Task itself — if the task
    # replies just as the timeout fires, Task.shutdown's flush picks up the reply
    # and returns {:ok, result}; only a genuine kill returns nil. Do not "fix"
    # this into something more elaborate; all five shapes below are reachable.
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
    do: if(RetrievalNode.Chunking.binary_content?(bin), do: {:error, :binary_content}, else: :ok)

  defp check_language_allowlist(lang, allowed),
    do: if(lang in allowed, do: :ok, else: {:error, :unsupported_language})

  defp parse_to_chunks(source, language) do
    with {:ok, root} <- parse_root(source, language) do
      {:ok, document_chunks(root, source, language)}
    end
  end

  # One parse, walked twice: chunk boundaries (extract/4) and the full-tree
  # graph walk. Only plain maps leave this function; `root` (a NIF node ref)
  # never escapes the guarded Task.
  defp parse_to_chunks_and_graph(source, language) do
    with {:ok, root} <- parse_root(source, language),
         {:ok, graph} <- Extractor.TreeSitter.extract({root, source}, language, []) do
      chunks = document_chunks(root, source, language)
      {:ok, %{chunks: chunks, entities: graph.entities, references: graph.references}}
    end
  end

  # Definition chunks plus the root-level gaps, in document order.
  defp document_chunks(root, source, language) do
    root
    |> extract(source, language, [])
    |> add_gaps(source, 0, byte_size(source), "")
    |> fill_gap_lines(source)
  end

  defp parse_root(source, language) do
    parser = TS.parser_new()

    case TS.parser_set_language(parser, language) do
      {:ok, {}} ->
        root =
          parser
          |> TS.parser_parse(source)
          |> TS.tree_root_node()

        {:ok, root}

      {:error, reason} ->
        {:error, {:language_load, reason}}
    end
  end

  defp extract(node, source, language, scope) do
    kinds = Map.get(@chunk_kinds, language, [])

    node
    |> named_children()
    |> Enum.flat_map(&extract_child(&1, source, language, scope, kinds))
  end

  defp extract_child(child, source, language, scope, kinds) do
    if chunk_boundary?(child, source, language, kinds) do
      emit_or_recurse(child, source, language, scope, TS.node_kind(child))
    else
      # Non-chunkable wrapper (block/body/decorator): descend, keep scope.
      extract(child, source, language, scope)
    end
  end

  # Elixir has no fixed boundary-kind set (see moduledoc): every construct is
  # a `call` node discriminated by its target identifier's text.
  defp chunk_boundary?(child, source, "elixir", _kinds) do
    TS.node_kind(child) == "call" and elixir_def_form?(child, source)
  end

  defp chunk_boundary?(child, _source, _language, kinds), do: TS.node_kind(child) in kinds

  defp elixir_def_form?(call_node, source) do
    case TS.node_child_by_field_name(call_node, "target") do
      nil ->
        false

      target_node ->
        TS.node_kind(target_node) == "identifier" and
          slice(source, target_node) in @elixir_def_forms
    end
  end

  # A chunkable node with chunkable descendants (a container, e.g. a class) yields
  # its members plus the gaps of its own range they leave uncovered (header,
  # docstring, fields), scoped to the container; a leaf-most one is emitted as a
  # chunk itself.
  defp emit_or_recurse(child, source, language, scope, kind) do
    child_scope = enclosing_scope(child, source, language, scope) ++ [node_name(child, source)]

    case extract(child, source, language, child_scope) do
      [] ->
        [to_chunk(child, source, kind, child_scope)]

      nested ->
        add_gaps(
          nested,
          source,
          TS.node_start_byte(child),
          TS.node_end_byte(child),
          Enum.join(child_scope, " > ")
        )
    end
  end

  # A rooted `defmodule Elixir.Foo` is absolute: it never nests under the
  # enclosing module, matching `Graph.Extractor.TreeSitter`.
  defp enclosing_scope(node, source, "elixir", scope) do
    case elixir_module_alias(node, source) do
      {_name, true} -> []
      _ -> scope
    end
  end

  defp enclosing_scope(_node, _source, _language, scope), do: scope

  # Collect direct named children in one O(n) cursor pass. The indexed
  # `node_named_child/2` accessor rescans from the first child each call (O(n²)
  # over siblings); the TreeCursor walks siblings in O(1) amortized.
  defp named_children(node) do
    cursor = TS.node_walk(node)

    if TS.treecursor_goto_first_child(cursor) do
      collect_siblings(cursor, [])
    else
      []
    end
  end

  defp collect_siblings(cursor, acc) do
    node = TS.treecursor_node(cursor)
    acc = if TS.node_is_named(node), do: [node | acc], else: acc

    if TS.treecursor_goto_next_sibling(cursor) do
      collect_siblings(cursor, acc)
    else
      Enum.reverse(acc)
    end
  end

  # Elixir boundary nodes are always kind "call"; every other language's
  # boundary kinds carry a "name" field directly.
  defp node_name(node, source) do
    case TS.node_kind(node) do
      "call" -> elixir_call_name(node, source) || "call"
      _ -> generic_node_name(node, source)
    end
  end

  defp generic_node_name(node, source) do
    case TS.node_child_by_field_name(node, "name") do
      nil -> TS.node_kind(node)
      name_node -> slice(source, name_node)
    end
  end

  defp elixir_call_name(call_node, source) do
    case TS.node_child_by_field_name(call_node, "target") do
      nil ->
        nil

      target_node ->
        case slice(source, target_node) do
          t when t in @elixir_module_forms ->
            call_node |> elixir_module_alias(source) |> alias_name()

          t when t in @elixir_function_forms ->
            elixir_def_name(call_node, source)

          _ ->
            nil
        end
    end
  end

  # defmodule/defprotocol/defimpl name from the first `alias` among their
  # arguments — `defimpl Sized, for: MyStruct` has a second alias, but it is
  # nested under the keyword list, not a direct child of `arguments`. The
  # absolute `Elixir.Foo` form is canonicalised to `{"Foo", true}` (rooted), as
  # in the extractor; non-rooted aliases are `{name, false}`.
  defp elixir_module_alias(call_node, source) do
    with args_node when not is_nil(args_node) <- elixir_arguments_node(call_node),
         alias_node when not is_nil(alias_node) <-
           args_node |> named_children() |> Enum.find(&(TS.node_kind(&1) == "alias")) do
      case slice(source, alias_node) do
        "Elixir." <> rest -> {rest, true}
        name -> {name, false}
      end
    end
  end

  defp alias_name({name, _rooted?}), do: name
  defp alias_name(nil), do: nil

  # def-family name from the first argument, in one of three shapes: a bare
  # identifier (zero-arity no-paren def), a nested `call` (the common
  # `def name(...)` case), or a `binary_operator` (a `when`-guard clause)
  # whose `left:` is the name-call.
  defp elixir_def_name(call_node, source) do
    with args_node when not is_nil(args_node) <- elixir_arguments_node(call_node),
         [first | _] <- named_children(args_node) do
      elixir_def_name_from(first, source)
    else
      _ -> nil
    end
  end

  # `arguments` is a plain positional child in this grammar, NOT reachable via
  # `node_child_by_field_name` — find it by kind among the call's named children.
  defp elixir_arguments_node(call_node) do
    call_node
    |> named_children()
    |> Enum.find(&(TS.node_kind(&1) == "arguments"))
  end

  defp elixir_def_name_from(node, source) do
    case TS.node_kind(node) do
      "call" ->
        case TS.node_child_by_field_name(node, "target") do
          nil -> nil
          target_node -> slice(source, target_node)
        end

      "identifier" ->
        slice(source, node)

      "binary_operator" ->
        case TS.node_child_by_field_name(node, "left") do
          nil -> nil
          left_node -> elixir_def_name_from(left_node, source)
        end

      _ ->
        nil
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
      parse_status: :ok,
      start_byte: TS.node_start_byte(node),
      end_byte: TS.node_end_byte(node)
    }
  end

  # --- top-level (gap) chunks -------------------------------------------

  # Merge `chunks` (sorted, non-overlapping, all within [from, to)) with the
  # gaps of [from, to) they leave uncovered, returned in document order.
  defp add_gaps(chunks, source, from, to, breadcrumb) do
    {gaps, cursor} =
      Enum.reduce(chunks, {[], from}, fn chunk, {acc, cursor} ->
        {gap_chunks(source, cursor, chunk.start_byte, breadcrumb) ++ acc, chunk.end_byte}
      end)

    tail = gap_chunks(source, cursor, to, breadcrumb)
    Enum.sort_by(chunks ++ gaps ++ tail, & &1.start_byte)
  end

  # Gap chunks for one uncovered byte range: trimmed to its non-whitespace
  # extent, then split into size-bounded line-aligned pieces.
  defp gap_chunks(source, from, to, breadcrumb) do
    case trim_range(source, from, to) do
      nil ->
        []

      {s, e} ->
        source
        |> split_range(s, e, s, [])
        |> Enum.flat_map(fn {ps, pe} -> piece_chunk(source, ps, pe, breadcrumb) end)
    end
  end

  defp piece_chunk(source, from, to, breadcrumb) do
    case trim_range(source, from, to) do
      nil -> []
      {s, e} -> [gap_chunk(source, s, e, breadcrumb)]
    end
  end

  # Cut at a blank line once the piece has reached the soft cap, or before the
  # line that would push it past the hard cap. A single line over the hard cap
  # stays one piece.
  defp split_range(_source, pos, limit, piece_start, acc) when pos >= limit do
    if piece_start < limit,
      do: Enum.reverse([{piece_start, limit} | acc]),
      else: Enum.reverse(acc)
  end

  defp split_range(source, pos, limit, piece_start, acc) do
    line_end = line_end(source, pos, limit)
    size = line_end - piece_start

    cond do
      pos > piece_start and size > HeuristicImpl.hard_max_bytes() ->
        split_range(source, pos, limit, pos, [{piece_start, pos} | acc])

      size >= HeuristicImpl.max_chunk_bytes() and blank_line?(source, pos, line_end) ->
        split_range(source, line_end, limit, line_end, [{piece_start, line_end} | acc])

      true ->
        split_range(source, line_end, limit, piece_start, acc)
    end
  end

  defp line_end(source, pos, limit) do
    case :binary.match(source, "\n", scope: {pos, limit - pos}) do
      {i, 1} -> i + 1
      :nomatch -> limit
    end
  end

  defp blank_line?(source, from, to), do: trim_range(source, from, to) == nil

  # Shrinks [from, to) to its non-whitespace extent (ASCII whitespace only), or
  # nil if it is all whitespace.
  defp trim_range(source, from, to) do
    from = skip_ws(source, from, to, 1)

    if from >= to, do: nil, else: {from, skip_ws(source, to - 1, from, -1) + 1}
  end

  defp skip_ws(source, pos, bound, step) do
    if pos != bound and :binary.at(source, pos) in ~c" \t\n\r\f\v" do
      skip_ws(source, pos + step, bound, step)
    else
      pos
    end
  end

  defp gap_chunk(source, start_byte, end_byte, breadcrumb) do
    %{
      text: binary_part(source, start_byte, end_byte - start_byte),
      breadcrumb: breadcrumb,
      kind: @toplevel_kind,
      parse_status: :ok,
      start_byte: start_byte,
      end_byte: end_byte
    }
  end

  # Gap chunks are born without lines; resolve them all against one newline
  # index (binary search) rather than rescanning the source per gap.
  defp fill_gap_lines(chunks, source) do
    if Enum.any?(chunks, &(&1.kind == @toplevel_kind)) do
      newlines = source |> :binary.matches("\n") |> Enum.map(&elem(&1, 0)) |> List.to_tuple()

      Enum.map(chunks, fn
        %{kind: @toplevel_kind} = c ->
          c
          |> Map.put(:start_line, line_at(newlines, c.start_byte))
          |> Map.put(:end_line, line_at(newlines, c.end_byte - 1))

        c ->
          c
      end)
    else
      chunks
    end
  end

  # 1-based line of `byte` = 1 + the number of newlines strictly before it.
  defp line_at(newlines, byte), do: 1 + count_before(newlines, byte, 0, tuple_size(newlines))

  defp count_before(_newlines, _byte, lo, hi) when lo >= hi, do: lo

  defp count_before(newlines, byte, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(newlines, mid) < byte,
      do: count_before(newlines, byte, mid + 1, hi),
      else: count_before(newlines, byte, lo, mid)
  end

  defp slice(source, node) do
    start_byte = TS.node_start_byte(node)
    end_byte = TS.node_end_byte(node)
    # tree-sitter always gives end >= start; guard anyway so a malformed offset
    # yields "" rather than a silent backwards read.
    if end_byte > start_byte, do: binary_part(source, start_byte, end_byte - start_byte), else: ""
  end
end
