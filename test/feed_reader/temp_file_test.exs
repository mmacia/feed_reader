defmodule FeedReader.TempFileTest do
  use ExUnit.Case, async: true

  alias FeedReader.TempFile

  test "returns a path in the system temporary directory" do
    path = TempFile.random_file()

    assert Path.dirname(path) == System.tmp_dir!()
    assert Path.extname(path) == ".xml"
    assert String.starts_with?(Path.basename(path), "feed_reader-")
  end

  test "uses the supplied base name" do
    path = TempFile.random_file("download")

    assert Path.basename(path) =~ ~r/^download-[0-9a-f]{32}\.xml$/
  end

  test "generates distinct paths without creating files" do
    paths = for _index <- 1..100, do: TempFile.random_file("feed")

    assert length(Enum.uniq(paths)) == 100
    refute Enum.any?(paths, &File.exists?/1)
  end
end
