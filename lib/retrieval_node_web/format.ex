defmodule RetrievalNodeWeb.Format do
  @moduledoc "Display helpers shared by the index inspection LiveViews."

  @doc ~s{Relative time ("3 min ago") for a DateTime/NaiveDateTime, or "never".}
  def ago(nil), do: "never"

  def ago(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> ago()

  def ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      s when s < 60 -> "#{max(s, 0)} s ago"
      s when s < 3600 -> "#{div(s, 60)} min ago"
      s when s < 86_400 -> "#{div(s, 3600)} h ago"
      s -> "#{div(s, 86_400)} d ago"
    end
  end

  @doc "Human byte size."
  def bytes(nil), do: "0 B"
  def bytes(n) when n < 1024, do: "#{n} B"
  def bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  @doc "Short label for a source type."
  def source_type(:git_repo), do: "git"
  def source_type(:jira_project), do: "jira"
  def source_type(:drive_folder), do: "drive"
  def source_type(other), do: to_string(other)

  @doc "Worker module name without the namespace."
  def worker(name) when is_binary(name), do: name |> String.split(".") |> List.last()

  @doc "Clip long text to `max` characters."
  def truncate(nil, _max), do: ""

  def truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
