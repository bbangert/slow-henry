defmodule RetrievalNode.Chunking.BreadcrumbTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Chunking.Breadcrumb

  test "joins a path prefix with a symbol trail (code)" do
    assert Breadcrumb.build("lib/foo.ex", "Foo > bar") == "lib/foo.ex > Foo > bar"
  end

  test "joins a doc title with a section (docs)" do
    assert Breadcrumb.build("Design Doc", "Overview") == "Design Doc > Overview"
  end

  test "returns just the prefix when the symbol trail is empty or nil" do
    assert Breadcrumb.build("lib/foo.ex", "") == "lib/foo.ex"
    assert Breadcrumb.build("lib/foo.ex", nil) == "lib/foo.ex"
  end

  test "prepends the breadcrumb to the chunk text" do
    assert Breadcrumb.prepend("lib/foo.ex > Foo", "def bar, do: :ok") ==
             "lib/foo.ex > Foo\n\ndef bar, do: :ok"
  end
end
