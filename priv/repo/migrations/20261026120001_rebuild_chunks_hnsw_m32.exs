defmodule RetrievalNode.Repo.Migrations.RebuildChunksHnswM32 do
  use Ecto.Migration

  # CONCURRENTLY builds cannot run inside a transaction or hold the migration
  # advisory lock.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # m = 16 / ef_construction = 64 had poor recall for natural-language queries
  # on the 693k-row corpus. Measured at hnsw.ef_search = 200: m = 32 /
  # ef_construction = 200 lifts bench recall@10 from 0.835 to 0.948 and
  # recall@200 from 0.695 to 0.878, at ~1241 MB vs ~1218 MB. A same-params
  # rebuild did not help, so this is a parameter problem, not index churn.
  #
  # The new index is built under a temporary name alongside the old one, so
  # queries keep using the old index until the swap. Budget ~1.2 GB of extra
  # disk during the build; the serial in-memory build took ~24.5 min on 693k
  # rows.
  def up, do: rebuild("m32", m: 32, ef_construction: 200)
  def down, do: rebuild("m16", m: 16, ef_construction: 64)

  # Everything runs on ONE checked-out connection: session SETs only apply to
  # the connection that issued them, and with the DDL transaction disabled each
  # queued `execute/1` may land on a different pooled connection. The first
  # build here ignored its SETs that way: it ran with the 64MB default
  # ("hnsw graph no longer fits into maintenance_work_mem after 24287 tuples")
  # and took 81 min instead of ~25. (The original chunk-index migration has the
  # same latent problem; it is already applied and left as is.)
  # The m = 32 graph for ~693k 384-dim rows is ~1.8 GB in memory, and the corpus
  # grows, so leave headroom (the ~24.5 min build above ran with 8 GB).
  @build_maintenance_work_mem "4GB"

  defp rebuild(tmp_suffix, m: m, ef_construction: ef) do
    tmp = "chunks_embedding_hnsw_#{tmp_suffix}_idx"

    repo().checkout(
      fn ->
        # The HNSW graph is held in maintenance_work_mem during the build.
        run!("SET maintenance_work_mem = '#{@build_maintenance_work_mem}'")

        # Parallel HNSW builds need dynamic shared memory; a small /dev/shm (as
        # in the devcontainer) makes them fail outright.
        run!("SET max_parallel_maintenance_workers = 0")

        %{rows: [[mem]]} = run!("SELECT current_setting('maintenance_work_mem')")

        if mem != @build_maintenance_work_mem do
          raise "maintenance_work_mem is #{mem} on the build connection, " <>
                  "expected #{@build_maintenance_work_mem}"
        end

        # Resumable from any interruption point, and never drops the only
        # valid HNSW index on chunks: a valid temp index is reused (the run
        # stopped after dropping the old index), an INVALID one is left over
        # from a failed CONCURRENTLY build and is rebuilt.
        case run!(
               """
               SELECT i.indisvalid FROM pg_index i
               JOIN pg_class c ON c.oid = i.indexrelid
               WHERE c.relname = $1
               """,
               [tmp]
             ).rows do
          [[true]] ->
            :ok

          state ->
            if state != [], do: run!("DROP INDEX CONCURRENTLY #{tmp}")

            run!("""
            CREATE INDEX CONCURRENTLY #{tmp}
            ON chunks USING hnsw (embedding vector_cosine_ops)
            WITH (m = #{m}, ef_construction = #{ef})
            """)
        end

        run!("DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_hnsw_idx")
        run!("ALTER INDEX #{tmp} RENAME TO chunks_embedding_hnsw_idx")
      end,
      timeout: :infinity
    )
  end

  defp run!(sql, params \\ []), do: repo().query!(sql, params, timeout: :infinity, log: :info)
end
