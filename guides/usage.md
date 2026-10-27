# Parsing feeds

FeedReader accepts local XML files, XML binaries, enumerables of XML chunks, and
remote URLs. Collection APIs return normalized metadata and items together;
streaming APIs expose the events as they are parsed. Collection requires an
explicit positive `:max_items` option.

## Parse a local file

```elixir
{:ok, result} = FeedReader.parse_file("priv/feed.xml", max_items: 500)

result.feed.title
result.items
```

The result is a `%FeedReader.ParseResult{feed: feed, items: items}`. The file
belongs to the caller and is not modified or removed. `:item_filter` can reject
items before they count toward `:max_items`:

```elixir
FeedReader.parse_file("priv/feed.xml",
  max_items: 500,
  item_filter: &(&1.language == :en)
)
```

`parse_binary/2` accepts an XML binary. `parse_stream/2` accepts an enumerable
of binary chunks; it writes chunks incrementally to a temporary file, parses
them, and removes the temporary file on success or failure. Both APIs use the
same parsing and collection options.

## Fetch and parse a remote URL

```elixir
{:ok, result} =
  FeedReader.fetch_and_parse("https://example.com/feed.xml", max_items: 500)

result.feed
result.items
result.fetch.etag
result.fetch.checksum
```

The returned `%FeedReader.RemoteResult{}` includes a `fetch` record with the
response ETag, decoded-body checksum, final URL, and HTTP status. The default
HTTP transport follows up to five redirects automatically. Custom transports
handle redirects themselves and must report the final URL. Remote collection
requires `:max_items` even when the server may return an unchanged outcome. The
item limit bounds the collected list; it does not limit response size or all
parsing work.
See [Resource limits](resource-limits.md) for the separate download and parser
budgets.

## Avoid reprocessing unchanged remote feeds

FeedReader is a good digital citizen: when given a saved ETag, it asks the server
whether the feed has changed and skips downloading the body if it hasn't. Keep
the latest remote ETag and decoded-body checksum in your application state. Pass
either or both on the next request:

```elixir
opts = [
  max_items: 500,
  previous_etag: saved_etag,
  previous_checksum: saved_checksum
]

case FeedReader.fetch_and_parse(url, opts) do
  {:ok, :not_modified} ->
    # The server confirmed the saved ETag with HTTP 304; no body was downloaded.
    :unchanged

  {:ok, :not_changed} ->
    # The decoded response checksum matched; the response body was downloaded,
    # but no parse result was produced.
    :unchanged

  {:ok, result} ->
    save_validators(result.fetch.etag, result.fetch.checksum)
    store(result)

  {:error, reason} ->
    handle_error(reason)
end
```

When provided, `:previous_etag` is sent as `If-None-Match`. If the server returns
304, FeedReader returns `{:ok, :not_modified}` without downloading or parsing a
body.
`:previous_checksum` is compared against the decoded response body, so that
check still downloads and checksums the body before returning
`{:ok, :not_changed}`. The checksum is a lowercase hexadecimal MD5 digest. On
either unchanged outcome there is no new `RemoteResult` or `Fetch` record.

## Avoid reparsing an unchanged local file

Local parsing has no built-in cache or `previous_checksum` option. Keep a file
fingerprint in your application and call `parse_file/2` only when it differs.
For example, a digest is robust against same-size replacements and timestamp
granularity:

```elixir
digest =
  "priv/feed.xml"
  |> File.read!()
  |> then(&:crypto.hash(:sha256, &1))

if digest != saved_digest do
  {:ok, result} = FeedReader.parse_file("priv/feed.xml", max_items: 500)
  store(result)
  save_digest(digest)
end
```

For large files, an application can instead use `File.stat/1` metadata as a
faster but less definitive fingerprint. `parse_file/2` reads and parses the
file when called; it does not compare against prior state.

## Select a format explicitly

FeedReader detects RSS, Atom, and RDF from a bounded prefix. If detection is
not appropriate for a source, specify a built-in ID or module:

```elixir
FeedReader.parse_file("priv/feed.xml", format: :atom, max_items: 500)
```

Custom formats can also be selected explicitly. See
[Customization](customization.md) for detection order and the format behavior.
