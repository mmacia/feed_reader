defmodule FeedReader.FormatDetectionTest do
  use ExUnit.Case, async: true

  alias FeedReader.FormatDetector.RootTag
  alias FeedReader.TestSupport.ExternalFormat

  test "detects RSS, Atom, and RDF from a bounded XML prefix" do
    assert FeedReader.detect_format("<?xml version='1.0'?><rss version='2.0'>") == :rss
    assert FeedReader.detect_format("<rss version='0.91'>") == :rss
    assert FeedReader.detect_format("<rss version='1.0'>") == :rss
    assert FeedReader.detect_format("<rss xmlns:xsi='urn:test'>") == :rss
    assert FeedReader.detect_format("<feed xmlns='http://www.w3.org/2005/Atom'>") == :atom
    assert FeedReader.detect_format("<a:feed xmlns:a='http://www.w3.org/2005/Atom'>") == :atom
    assert FeedReader.detect_format("<feed/>") == :atom

    assert FeedReader.detect_format(
             "<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
           ) == :rdf

    assert FeedReader.detect_format("<html><body>not a feed</body></html>") == :unknown
  end

  test "Atom root detection guards RSS false signatures and preserves RSS priority" do
    atom_with_rss =
      ~s(<a:feed xmlns:a="http://www.w3.org/2005/Atom"><rss version="2.0"/></a:feed>)

    atom_without_namespace_with_rss = "<feed><rss version='2.0'/></feed>"

    rss_with_atom =
      ~s(<rss version="2.0"><channel><feed xmlns="http://www.w3.org/2005/Atom"/></channel></rss>)

    assert FeedReader.detect_format(atom_with_rss) == :atom
    assert FeedReader.detect_format(atom_without_namespace_with_rss) == :rss
    assert FeedReader.detect_format(rss_with_atom) == :rss

    assert FeedReader.detect_format(
             "<container><feed xmlns='http://www.w3.org/2005/Atom'/></container>"
           ) ==
             :unknown
  end

  test "RDF detection requires a complete root and the RDF namespace" do
    rdf_namespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    default_root = ~s(<RDF xmlns="#{rdf_namespace}"/>)
    aliased_root = ~s(<r:RDF xmlns:r="#{rdf_namespace}"/>)
    legacy_root = "<rdf:RDF/>"
    wrong_namespace = ~s(<rdf:RDF xmlns:rdf="urn:foreign"/>)
    rdf_with_rss = ~s(<r:RDF xmlns:r="#{rdf_namespace}"><rss version="2.0"/></r:RDF>)

    assert FeedReader.detect_format(default_root) == :rdf
    assert FeedReader.detect_format(aliased_root) == :rdf
    assert FeedReader.detect_format(legacy_root) == :rdf
    assert FeedReader.detect_format(rdf_with_rss) == :rdf
    assert FeedReader.detect_format(wrong_namespace) == :unknown
    assert FeedReader.detect_format("<rdf:RDF") == :unknown
    assert FeedReader.detect_format("<container><rdf:RDF/></container>") == :unknown

    # Validation checks the explicitly selected format's prefix signature;
    # automatic detection is namespace-aware.
    assert FeedReader.validate(wrong_namespace, :rdf)

    explicit_root = "<RDF><channel><title>Explicit RDF</title></channel></RDF>"
    assert FeedReader.detect_format(explicit_root) == :unknown

    assert {:ok, %{feed: %{title: "Explicit RDF"}}} =
             FeedReader.parse_binary(explicit_root, format: :rdf)
  end

  test "RDF detection honors complete-root byte cutoffs" do
    root = ~s(<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#">)
    content = root <> "tail</r:RDF>"

    assert FeedReader.detect_format(content, max_detection_bytes: byte_size(root) - 1) == :unknown
    assert FeedReader.detect_format(content, max_detection_bytes: byte_size(root)) == :rdf
  end

  test "probes complete root tags after comments and handles quoted delimiters" do
    assert {:ok, %{name: "rdf:RDF", attributes: [{"note", "a > b"}]}} =
             RootTag.probe("<!-- <rss> --><?xml version='1.0'?><rdf:RDF note=\"a > b\">")

    assert :incomplete = RootTag.probe("<rdf:RDF")
    assert :incomplete = RootTag.probe("<root note='unfinished")
    assert :incomplete = RootTag.probe("<!DOCTYPE root")

    assert {:ok, %{name: "root", attributes: []}} =
             RootTag.probe(" \n<!DOCTYPE root><![CDATA[<rss>]]><root/>")

    assert {:ok, %{name: "root", attributes: []}} =
             RootTag.probe("<?xml-stylesheet?> \n<root>")

    assert Enum.all?(["", "<!--"], &(RootTag.probe(&1) == :incomplete))
    assert RootTag.probe("<?xml") == :incomplete
    assert RootTag.probe("<?xml version='1.0'") == :incomplete

    assert Enum.all?(["text", "<>", "<root key=value>", 1], &(RootTag.probe(&1) == :invalid))
  end

  test "returns incomplete for truncated markup and delimiters" do
    for prefix <- [
          "<",
          "<!",
          "<!ELEMENT feed",
          ~s|<!DOCTYPE feed SYSTEM "quoted > unfinished|,
          "<!-- unfinished",
          "<?probe",
          "<?probe content>",
          ~s|<feed note="quoted > unfinished|,
          "<![CDATA[unfinished"
        ] do
      assert :incomplete = RootTag.probe(prefix)
    end
  end

  test "probes past a UTF-8 BOM and declarations using supported encodings" do
    for encoding <- ["UTF-8", "US-ASCII"] do
      assert {:ok, %{name: "root", attributes: []}} =
               RootTag.probe(~s(<?xml version="1.0" encoding="#{encoding}"?><root/>))
    end

    assert {:ok, %{name: "root", attributes: []}} =
             RootTag.probe(<<0xEF, 0xBB, 0xBF>> <> " \n<?xml version='1.0'?><root/>")

    latin1 =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?><root title="caf) <> <<0xE9>> <> ~s("/>)

    assert {:ok, %{name: "root", attributes: [{"title", "café"}]}} = RootTag.probe(latin1)
  end

  test "expands XML character references in root attributes" do
    expected = "&<>\"'AA\t" <> <<0xE000::utf8, 0x10000::utf8>>

    assert {:ok, %{attributes: [{"a", ^expected}]}} =
             RootTag.probe(~s(<r a="&amp;&lt;&gt;&quot;&apos;&#65;&#X41;&#9;&#xE000;&#x10000;"/>))

    for reference <- ["&unknown;", "&broken"] do
      assert {:ok, %{attributes: [{"value", ^reference}]}} =
               RootTag.probe(~s(<root value="#{reference}"/>))
    end

    assert :invalid = RootTag.probe(~s(<root value="&#0;"/>))
    assert :invalid = RootTag.probe(~s(<root value="&AMP;"/>))
    assert :invalid = RootTag.probe(~s|<root value="<!-- &broken"> -->|)
  end

  test "automatic detection applies entity recovery to root attributes" do
    atom_namespace = "http://www.w3.org/2005/Atom"

    for value <- ["A & B", "A &unknown; B", ~s(How to "Sustain Heroku")] do
      xml = "<feed xmlns='#{atom_namespace}' note=\"#{value}\"><title>News</title></feed>"

      assert FeedReader.detect_format(xml) == :atom
      assert {:ok, %{feed: %{title: "News"}}} = FeedReader.parse_binary(xml)
    end
  end

  test "does not probe past a byte-limited prefix" do
    prefix = <<0xEF, 0xBB, 0xBF>> <> " \n<?xml version='1.0'?><feed xmlns='urn:test'/>"

    assert {:ok, %{name: "feed", attributes: [{"xmlns", "urn:test"}]}} = RootTag.probe(prefix)

    assert :incomplete = RootTag.probe(binary_part(prefix, 0, byte_size(prefix) - 1))
    assert :incomplete = RootTag.probe(<<0xEF>>)
    assert :incomplete = RootTag.probe(<<0xEF, 0xBB>>)
  end

  test "classifies Atom roots by default, aliased, and namespace-less forms" do
    atom_namespace = "http://www.w3.org/2005/Atom"

    for {prefix, expected} <- [
          {~s(<feed xmlns="#{atom_namespace}"/>), :atom},
          {~s(<a:feed xmlns:a="#{atom_namespace}"/>), :atom},
          {"<feed/>", :atom},
          {~s(<feed xmlns="urn:foreign"/>), :unknown},
          {~s(<a:feed xmlns:a="urn:foreign"/>), :unknown},
          {"<a:feed/>", :unknown},
          {"<rss/>", :unknown}
        ] do
      assert RootTag.classify(prefix) == expected
    end
  end

  test "classifies scoped and legacy RDF roots and rejects wrong bindings" do
    rdf_namespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    for {prefix, expected} <- [
          {~s(<RDF xmlns="#{rdf_namespace}"/>), :rdf},
          {~s(<r:RDF xmlns:r="#{rdf_namespace}"/>), :rdf},
          {"<rdf:RDF/>", :rdf},
          {~s(<RDF xmlns="urn:foreign"/>), :unknown},
          {~s(<rdf:RDF xmlns:rdf="urn:foreign"/>), :unknown},
          {~s(<rdf:RDF xmlns:rdf=""/>), :unknown},
          {"<x:RDF/>", :unknown},
          {"<RDF/>", :unknown},
          {"<rdf:RDF", :unknown},
          {"not xml", :unknown}
        ] do
      assert RootTag.classify(prefix) == expected
    end

    assert RootTag.classify(:not_binary) == :unknown
  end

  test "custom format detection replays the bounded prefix and unread chunks" do
    chunks = ["<external-feed>tail", "continued"]

    {format, _prefix, replay} =
      FeedReader.FormatDetector.detect_and_replay(chunks,
        formats: [ExternalFormat],
        max_detection_bytes: 15
      )

    assert format == :external_test
    assert replay |> Enum.to_list() |> IO.iodata_to_binary() == IO.iodata_to_binary(chunks)

    assert FeedReader.detect_format("<external-feed><feed/>", formats: [ExternalFormat]) ==
             :external_test

    assert FeedReader.detect_format("<feed><rss version='2.0'>") == :rss
  end

  test "Atom detection replays its bounded prefix and unread chunks" do
    prefix = ~s(<feed xmlns="http://www.w3.org/2005/Atom"><rss version="2.0">)
    chunks = [prefix, "tail</feed>"]

    {format, detected_prefix, replay} =
      FeedReader.FormatDetector.detect_and_replay(chunks, max_detection_bytes: byte_size(prefix))

    assert format == :atom
    assert detected_prefix == prefix
    assert replay |> Enum.to_list() |> IO.iodata_to_binary() == IO.iodata_to_binary(chunks)
  end

  test "RDF detection replays its bounded prefix and unread chunks" do
    prefix = ~s(<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#">)
    chunks = [prefix, "tail</r:RDF>"]

    {format, detected_prefix, replay} =
      FeedReader.FormatDetector.detect_and_replay(chunks, max_detection_bytes: byte_size(prefix))

    assert format == :rdf
    assert detected_prefix == prefix
    assert replay |> Enum.to_list() |> IO.iodata_to_binary() == IO.iodata_to_binary(chunks)
  end

  test "detection does not inspect content beyond the configured prefix" do
    content = String.duplicate("x", 12) <> "<rss version='2.0'>"

    assert FeedReader.detect_format(content, max_detection_bytes: 12) == :unknown
    assert FeedReader.detect_format(content, max_detection_bytes: 40) == :rss
  end

  test "detection fails closed for unsupported inputs and invalid limits" do
    assert FeedReader.FormatDetector.detect(:not_binary, []) == :unknown
    refute FeedReader.FormatDetector.validate(nil, :rss, [])
    refute FeedReader.validate("<rss version='2.0'>", :rss, max_detection_bytes: 0)

    {format, _prefix, _replay} = FeedReader.FormatDetector.detect_and_replay([:not_binary], [])
    assert format == :unknown
    refute FeedReader.FormatDetector.validate("<rss version='2.0'>", "rss", [])

    source = ["<rss version='2.0'>"]

    assert FeedReader.FormatDetector.detect_and_replay(source, max_detection_bytes: 0) ==
             {:unknown, "", source}
  end

  test "enumerable detection finalizes when the source ends before its prefix limit" do
    source = ["<rss version='2.0'>"]

    {format, prefix, replay} =
      FeedReader.FormatDetector.detect_and_replay(source, max_detection_bytes: 64)

    assert format == :rss
    assert prefix == hd(source)
    assert Enum.to_list(replay) == [prefix]
  end

  test "validation checks only the explicitly selected format" do
    rss = "<rss version='2.0'><channel></channel></rss>"

    assert FeedReader.validate(rss, :rss)
    assert FeedReader.validate(rss, FeedReader.Formats.RSS)
    refute FeedReader.validate(rss, :atom)
    refute FeedReader.validate(rss, :unknown)
    assert FeedReader.validate("<external-feed>", ExternalFormat)
  end
end
