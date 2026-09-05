defmodule RetrievalNode.Chunking.ResumeConcurrencyProbe do
  @moduledoc """
  Test-only `Chunking` impl for `ResumeCoordinatorTest`: on each `chunk/2` it
  records the number of simultaneous in-flight chunk calls into an Agent named
  `#{inspect(__MODULE__)}` (the test starts it), briefly sleeps so overlap is
  observable, then returns one trivial chunk. Lets a test assert the peak
  concurrency the coordinator's bounded resume actually reaches.
  """
  @behaviour RetrievalNode.Chunking

  @chunk %{
    text: "x",
    breadcrumb: "b",
    start_line: 1,
    end_line: 1,
    kind: "function_definition",
    parse_status: :ok
  }

  @impl true
  def chunk(_source, _lang) do
    Agent.update(__MODULE__, fn %{cur: c, peak: p} -> %{cur: c + 1, peak: max(p, c + 1)} end)
    Process.sleep(40)
    Agent.update(__MODULE__, fn %{cur: c} = s -> %{s | cur: c - 1} end)
    {:ok, [@chunk]}
  end

  @impl true
  def allowed_languages, do: []
end
