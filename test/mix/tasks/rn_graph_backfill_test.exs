defmodule Mix.Tasks.Rn.Graph.BackfillTest do
  # Pure function only — parse_args/1 is pulled out of run/1 specifically so
  # it's testable without booting the app (run/1 calls boot/0, which starts
  # Oban/Endpoint/the embedding sub-tree). No DB access needed here.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Rn.Graph.Backfill

  describe "parse_args/1" do
    test "no args parses to an empty opts list" do
      assert Backfill.parse_args([]) == {:ok, []}
    end

    test "--status parses to status: true" do
      assert Backfill.parse_args(["--status"]) == {:ok, [status: true]}
    end

    test "an unknown flag is rejected instead of silently falling through" do
      assert {:error, message} = Backfill.parse_args(["--statsu"])
      assert message =~ "--statsu"
      assert message =~ "Usage"
    end

    test "a stray positional argument is rejected" do
      assert {:error, message} = Backfill.parse_args(["bogus"])
      assert message =~ "bogus"
    end

    test "a flag plus a stray positional argument are both named as offenders" do
      assert {:error, message} = Backfill.parse_args(["--status", "extra"])
      assert message =~ "extra"
    end

    test "--status given a non-boolean value is rejected" do
      assert {:error, message} = Backfill.parse_args(["--status=bogus"])
      assert message =~ "--status"
    end
  end
end
