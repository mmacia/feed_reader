defmodule FeedReader.StreamingTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Item, Session}

  @xml ~s(<rss version="2.0"><channel><title>Example</title><link>https://example.com/</link><item><title>First</title><guid>one</guid></item><item><title>Second</title><guid>two</guid></item></channel></rss>)
  @atom_xml ~s(<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title></feed>)
  @rdf_xml ~s(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><channel><title>RDF</title></channel></rdf:RDF>)

  test "emits feed metadata before items in one local pass" do
    path = write_temp(@xml)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %Session{fetch: nil, events: events}} = FeedReader.stream_file(path)

    assert [
             {:feed, %Feed{title: "Example"}},
             {:item, %Item{uuid: "one"}},
             {:item, %Item{uuid: "two"}}
           ] = Enum.to_list(events)

    assert File.read!(path) == @xml
  end

  test "delivers a malformed tail as a terminal error after earlier events" do
    xml = @xml <> "<broken"
    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    events = Enum.to_list(events)

    assert {:feed, %Feed{}} = Enum.at(events, 0)
    assert {:item, %Item{uuid: "one"}} = Enum.at(events, 1)
    assert {:item, %Item{uuid: "two"}} = Enum.at(events, 2)
    assert {:error, _reason} = Enum.at(events, 3)
    assert length(events) == 4
    assert File.read!(path) == xml
  end

  test "rejects an unknown local format before creating a session" do
    path = write_temp("<not-a-feed/>")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :unknown} = FeedReader.stream_file(path)
    assert File.read!(path) == "<not-a-feed/>"
  end

  test "validates local paths and accepts an explicitly selected format module" do
    assert {:error, :invalid_path} = FeedReader.stream_file(123)
    assert {:error, :enoent} = FeedReader.stream_file("/path/that/does/not/exist")

    assert {:error, :not_a_file} = FeedReader.stream_file(System.tmp_dir!())

    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path, format: FeedReader.Formats.RSS)

    assert {:feed, %Feed{type: :rss}} = Enum.at(Enum.to_list(events), 0)
  end

  test "accepts explicit built-in Atom and RDF format IDs" do
    atom_path = write_temp(@atom_xml)
    rdf_path = write_temp(@rdf_xml)

    on_exit(fn ->
      File.rm(atom_path)
      File.rm(rdf_path)
    end)

    assert {:ok, %{events: atom_events}} = FeedReader.stream_file(atom_path, format: :atom)
    assert [{:feed, %Feed{title: "Atom", type: :atom}}] = Enum.to_list(atom_events)

    assert {:ok, %{events: rdf_events}} = FeedReader.stream_file(rdf_path, format: :rdf)
    assert [{:feed, %Feed{title: "RDF", type: :rdf}}] = Enum.to_list(rdf_events)
  end

  test "resolves a custom format by its ID" do
    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path,
               format: :external_test,
               formats: [FeedReader.TestSupport.ExternalFormat]
             )

    assert [] = Enum.to_list(events)
  end

  test "uses an explicit format even when detection is disabled" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path, format: :rss, max_detection_bytes: 0)

    assert {:feed, %Feed{type: :rss}} = Enum.at(Enum.to_list(events), 0)
  end

  test "closes the parser when the consumer stops early" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    assert [{:feed, %Feed{}}] = events |> Stream.take(1) |> Enum.to_list()
    assert File.read!(path) == @xml
  end

  test "returns a stable error for a non-atom format option" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:error, :unknown} = FeedReader.stream_file(path, format: "rss")
  end

  test "treats an invalid detection limit as an unknown format" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:error, :unknown} = FeedReader.stream_file(path, max_detection_bytes: 0)
  end

  test "delivers a parser halt as a terminal error event" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(
               path,
               format: :parser_halt,
               formats: [FeedReader.TestSupport.ParserHaltFormat]
             )

    assert [{:error, :parser_halted}] = Enum.to_list(events)
  end

  test "stops cleanly when the parser process exits normally" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path,
               format: :parser_halt,
               formats: [FeedReader.TestSupport.ParserHaltFormat],
               normal_exit: true
             )

    assert [] = Enum.to_list(events)
  end

  defp write_temp(content) do
    path = Path.join(System.tmp_dir!(), "feed_reader-#{System.unique_integer([:positive])}.xml")
    File.write!(path, content)
    path
  end
end
