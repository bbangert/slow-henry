defmodule RetrievalNode.Chunking.TreeSitterCoverageTest do
  # Coverage invariant: every non-whitespace byte of a tree-sitter-chunked file
  # belongs to exactly one chunk. One checker, run over a realistic fixture per
  # allowed language and a shared set of edge-case transformations of it.
  # async: false — shares the application-owned ChunkTaskSupervisor with
  # TreeSitterImplTest, which tears it down.
  use ExUnit.Case, async: false

  @moduletag :tree_sitter

  alias RetrievalNode.Chunking.HeuristicImpl
  alias RetrievalNode.Chunking.TreeSitterImpl, as: TSI

  @ws [?\s, ?\t, ?\n, ?\r, ?\f, ?\v]

  # {language, fixture, {marker, breadcrumb}} — `marker` is a class-body line
  # sitting between two members; its toplevel chunk must carry `breadcrumb`.
  # `stmt` renders one top-level statement/comment line carrying `pad`.
  @fixtures [
    {"python",
     ~S'''
     # Copyright (c) 2026 Example — héllo 世界
     """Module docstring."""
     import os
     from typing import List

     LIMIT = 3
     __all__ = ["Widget", "build"]

     print("loading")


     def decorator(fn):
         return fn


     @decorator
     def build(n):
         return n * LIMIT


     class Widget:
         """A widget."""

         tally = 0

         def __init__(self):
             self.x = "é"

         registry = {}

         def run(self):
             return build(self.x)


     if __name__ == "__main__":
         build(1)
     ''', {"registry = {}", "Widget"}, ~S|X#{i} = "#{pad}"|},
    {"javascript",
     ~S"""
     // Copyright 2026 — héllo 世界
     import fs from "fs";
     const LIMIT = 3;
     console.log("loading");

     export function build(n) {
       return n * LIMIT;
     }

     class Widget {
       static count = 0;
       constructor() { this.x = "é"; }
       registry = {};
       run() { return build(this.x); }
     }

     module.exports = { Widget };
     """, {"registry = {};", "Widget"}, ~S|const x#{i} = "#{pad}";|},
    {"typescript",
     ~S"""
     // Copyright 2026 — héllo 世界
     import { readFileSync } from "fs";
     const LIMIT: number = 3;

     interface Opts {
       a: number;
     }

     type Id = string;

     @sealed
     class Widget {
       static count = 0;
       constructor(private x: string = "é") {}
       registry: Record<string, number> = {};
       run(): string { return this.x; }
     }

     enum Color { Red, Green }

     console.log("loading", LIMIT);
     """, {"registry: Record<string, number> = {};", "Widget"}, ~S|const x#{i} = "#{pad}";|},
    {"go",
     ~S"""
     // Copyright 2026 — héllo 世界
     package main

     import "fmt"

     const Limit = 3

     var registry = map[string]int{}

     func build(n int) int {
     	return n * Limit
     }

     type Widget struct {
     	x string
     }

     func (w *Widget) Run() string {
     	return fmt.Sprint(w.x, "é")
     }

     func init() {
     	fmt.Println("loading")
     }
     """, nil, ~S|var x#{i} = "#{pad}"|},
    {"rust",
     ~S"""
     // Copyright 2026 — héllo 世界
     use std::fmt;

     const LIMIT: u32 = 3;
     static NAME: &str = "é";

     #[derive(Debug)]
     struct Widget {
         x: u32,
     }

     mod util {
         const INNER: u32 = 1;

         pub fn build(n: u32) -> u32 {
             n * INNER
         }

         pub const REGISTRY: u32 = 2;

         pub fn run() -> u32 {
             build(2)
         }
     }

     impl Widget {
         fn new() -> Self { Widget { x: 0 } }
     }

     fn main() {
         println!("{}", LIMIT);
     }
     """, {"pub const REGISTRY: u32 = 2;", "util"}, ~S|const X#{i}: &str = "#{pad}";|},
    {"ruby",
     ~S"""
     # Copyright 2026 — héllo 世界
     require "json"

     LIMIT = 3
     puts "loading"

     def build(n)
       n * LIMIT
     end

     class Widget
       attr_reader :x

       def initialize
         @x = "é"
       end

       REGISTRY = {}

       def run
         build(@x)
       end
     end

     Widget.new.run
     """, {"REGISTRY = {}", "Widget"}, ~S|X#{i} = "#{pad}"|},
    {"java",
     ~S"""
     // Copyright 2026 — héllo 世界
     package com.example;

     import java.util.List;

     @SuppressWarnings("unused")
     public class Widget {
         private static final int LIMIT = 3;
         private String x = "é";

         public Widget() {
             this.x = "w";
         }

         private int registry = 0;

         @Override
         public String toString() {
             return x;
         }
     }

     // end of file
     """, {"private int registry = 0;", "Widget"}, ~S|import a.b.C#{i}; // #{pad}|},
    {"elixir",
     ~S"""
     # Copyright 2026 — héllo 世界
     defmodule Widget do
       @moduledoc "A widget é."
       use GenServer
       alias Foo.Bar

       @limit 3

       def build(n), do: n * @limit

       @registry %{}

       @doc "Runs."
       def run(x) do
         build(x)
       end
     end

     IO.puts("loading")
     """, {"@registry %{}", "Widget"}, ~S|@x#{i} "#{pad}"|}
  ]

  for {lang, fixture, marker, stmt} <- @fixtures do
    describe "coverage invariant: #{lang}" do
      @lang lang
      @fixture fixture
      @marker marker
      @stmt stmt

      test "realistic fixture" do
        chunks = assert_covered(@fixture, @lang)
        assert Enum.any?(chunks, &(&1.kind == "toplevel"))
        assert_marker(chunks, @marker)
      end

      test "CRLF line endings" do
        chunks = assert_covered(String.replace(@fixture, "\n", "\r\n"), @lang)
        assert_marker(chunks, @marker)
      end

      test "no definitions, whitespace-only and single very long line" do
        source = render_stmt(@stmt, 1, "x") <> "\n" <> render_stmt(@stmt, 2, "y") <> "\n"
        assert [%{kind: "toplevel", parse_status: :ok}] = assert_covered(source, @lang)

        assert {:ok, []} = TSI.chunk("  \n\t\n\r\n", @lang)

        long = render_stmt(@stmt, 1, String.duplicate("a", 10_000)) <> "\n"
        assert [%{kind: "toplevel"}] = assert_covered(long, @lang)
      end

      test "a gap larger than the hard cap is split, with and without blank lines" do
        lines = for i <- 1..400, do: render_stmt(@stmt, i, "padding padding")

        blanked =
          lines |> Enum.chunk_every(10) |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))

        for big <- [blanked, Enum.join(lines, "\n")] do
          chunks = assert_covered(big <> "\n\n" <> @fixture, @lang)
          assert Enum.count(chunks, &(&1.kind == "toplevel" and &1.text =~ "padding")) > 1
        end
      end

      test "chunk_with_graph/2 returns the same chunks as chunk/2" do
        {:ok, chunks} = TSI.chunk(@fixture, @lang)
        assert {:ok, %{chunks: ^chunks}} = TSI.chunk_with_graph(@fixture, @lang)
      end
    end
  end

  describe "gap splitting" do
    test "pieces break at blank lines once past the soft cap" do
      para = Enum.map_join(1..5, "\n", &"VALUE_#{&1} = \"some padding text here\"")
      source = Enum.map_join(1..30, "\n\n", fn _ -> para end) <> "\n"

      chunks = assert_covered(source, "python")
      assert length(chunks) > 1

      chunks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert byte_size(a.text) >= HeuristicImpl.max_chunk_bytes()
        assert binary_part(source, a.end_byte, b.start_byte - a.end_byte) =~ "\n\n"
      end)
    end
  end

  describe "elixir toplevel coverage" do
    test "ExUnit, schema, @moduledoc and use lines are toplevel chunks under the module" do
      src = """
      defmodule PayTest do
        @moduledoc "Covers the payment flow."
        use ExUnit.Case
        use Ecto.Schema

        schema "payments" do
          field :amount, :integer
        end

        def helper(x), do: x

        describe "pay" do
          test "pays the order" do
            assert helper(1) == 1
          end
        end
      end
      """

      chunks = assert_covered(src, "elixir")
      toplevel = Enum.filter(chunks, &(&1.kind == "toplevel"))

      for needle <- ["@moduledoc", "use ExUnit.Case", ~s(schema "payments"), ~s(test "pays)] do
        assert [%{breadcrumb: "PayTest"}] = Enum.filter(toplevel, &(&1.text =~ needle))
      end
    end
  end

  # --- the one checker ------------------------------------------------------

  defp render_stmt(template, i, pad) do
    template |> String.replace("\#{i}", Integer.to_string(i)) |> String.replace("\#{pad}", pad)
  end

  defp assert_marker(_chunks, nil), do: :ok

  defp assert_marker(chunks, {marker, breadcrumb}) do
    assert [chunk] = Enum.filter(chunks, &(&1.kind == "toplevel" and &1.text =~ marker))
    assert chunk.breadcrumb == breadcrumb
  end

  defp assert_covered(source, language) do
    assert {:ok, chunks} = TSI.chunk(source, language)

    assert chunks == Enum.sort_by(chunks, & &1.start_byte), "not in document order"

    # Chunks tile the file: between consecutive chunks (and at both ends) only
    # whitespace remains, and no chunk starts before its predecessor ends.
    {last_end, _} =
      Enum.reduce(chunks, {0, nil}, fn chunk, {cursor, _} ->
        assert chunk.start_byte >= cursor, "overlap at byte #{chunk.start_byte}"
        assert blank?(binary_part(source, cursor, chunk.start_byte - cursor)), "uncovered bytes"

        assert chunk.text ==
                 binary_part(source, chunk.start_byte, chunk.end_byte - chunk.start_byte)

        {chunk.end_byte, chunk}
      end)

    assert blank?(binary_part(source, last_end, byte_size(source) - last_end)), "uncovered tail"

    for %{kind: "toplevel"} = chunk <- chunks do
      assert chunk.parse_status == :ok
      refute chunk.text == ""
      refute :binary.first(chunk.text) in @ws, "leading whitespace"
      refute :binary.last(chunk.text) in @ws, "trailing whitespace"
      assert chunk.start_line == line_of(source, chunk.start_byte)
      assert chunk.end_line == line_of(source, chunk.end_byte - 1)

      assert byte_size(chunk.text) <= HeuristicImpl.hard_max_bytes() or
               not String.contains?(chunk.text, "\n"),
             "toplevel chunk over the hard cap"
    end

    chunks
  end

  defp blank?(bin), do: bin |> :binary.bin_to_list() |> Enum.all?(&(&1 in @ws))

  defp line_of(source, byte),
    do: 1 + (source |> binary_part(0, byte) |> :binary.matches("\n") |> length())
end
