defmodule FeedReader.StreamingTest do
  use ExUnit.Case, async: true

  alias FeedReader.{Feed, Item, Session}
  import ExUnit.CaptureLog

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

  test "stops at the root and ignores trailing content" do
    xml = @xml <> "<broken"
    path = write_temp(xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)
    events = Enum.to_list(events)

    assert {:feed, %Feed{}} = Enum.at(events, 0)
    assert {:item, %Item{uuid: "one"}} = Enum.at(events, 1)
    assert {:item, %Item{uuid: "two"}} = Enum.at(events, 2)
    assert length(events) == 3
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

  test "does not retain an event larger than the pending queue budget" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path, max_queue_bytes: 1)
    assert [{:error, {:resource_limit, :max_queue_bytes, 1}}] = Enum.to_list(events)
  end

  test "cancelling enumeration stops before the next item is parsed" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)

    assert [{:feed, %Feed{}}, {:item, %Item{uuid: "one"}}] =
             events |> Stream.take(2) |> Enum.to_list()
  end

  test "cleans up the parser when the consumer raises" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} = FeedReader.stream_file(path)

    _log =
      capture_log(fn ->
        {:ok, consumer} =
          Task.start(fn -> Enum.each(events, fn _event -> raise "consumer failed" end) end)

        monitor = Process.monitor(consumer)

        assert_receive {:DOWN, ^monitor, :process, ^consumer, {%RuntimeError{}, _stack}}
      end)
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

  test "uses queue defaults when queue limits are invalid" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path, max_item_bytes: :invalid, max_queue_bytes: :invalid)

    assert {:feed, %Feed{title: "Example"}} = Enum.at(Enum.to_list(events), 0)
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

  test "delivers an abnormal parser exit as an error event" do
    path = write_temp(@xml)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path,
               format: :parser_halt,
               formats: [FeedReader.TestSupport.ParserHaltFormat],
               abnormal_exit: true
             )

    assert [{:error, :parser_crashed}] = Enum.to_list(events)
  end

  test "stops the parser when the consuming process dies" do
    path = write_temp("<external-feed/>")
    on_exit(fn -> File.rm(path) end)
    test_pid = self()

    assert {:ok, %{events: events}} =
             FeedReader.stream_file(path,
               format: :external_test,
               formats: [FeedReader.TestSupport.ExternalFormat],
               notify_parser: test_pid,
               emit_event: true
             )

    consumer =
      spawn(fn ->
        Enum.each(events, fn event ->
          send(test_pid, {:event, event})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:parser_pid, parser}, 500
    assert_receive {:event, {:feed, %Feed{title: "External"}}}, 500
    parser_monitor = Process.monitor(parser)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^parser_monitor, :process, ^parser, :normal}, 500
  end

  defp write_temp(content) do
    path = Path.join(System.tmp_dir!(), "feed_reader-#{System.unique_integer([:positive])}.xml")
    File.write!(path, content)
    path
  end
end
