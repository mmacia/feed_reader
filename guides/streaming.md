# Streaming and verified parsing

Streaming APIs return a `%FeedReader.Session{}` containing a one-pass
`events` enumerable. Events are delivered in order: one `{:feed, feed}` event
followed by normalized `{:item, item}` events. A parser error is emitted as a
terminal `{:error, reason}` event. Errors that happen before a session can be
created, such as an unknown format or a failed remote request, are returned
directly as `{:error, reason}`.

Streaming APIs do not enforce `:max_items`; it applies to collection APIs such as
`parse_file/2`, `parse_stream/2`, and `fetch_and_parse/2`. A stream emits items as
the consumer enumerates them. Stop enumeration in the consumer to limit how many
events are processed.

## Stream a local file

```elixir
{:ok, session} = FeedReader.stream_file("priv/feed.xml")

session.events
|> Enum.each(fn
  {:feed, feed} -> save_feed_metadata(feed)
  {:item, item} -> process_item(item)
  {:error, reason} -> handle_parse_error(reason)
end)
```

The local file remains caller-owned, even if enumeration stops early. The
parser runs on demand and only advances as events are requested. `:chunk_size`
controls input chunks and SAX character-data callback sizing.

## Stream a remote URL

```elixir
{:ok, session} = FeedReader.stream("https://example.com/feed.xml")

try do
  session.events
  |> Enum.take(20)
  |> Enum.each(&process_event/1)
after
  FeedReader.close(session)
end
```

`Enum.take/2` limits events, including the initial feed-metadata event; it does
not count only item events.

Remote sessions include a `fetch` record. The remote response is downloaded,
decoded, checksummed, and staged in an owned temporary file before
`stream/2` returns. Parsing the staged file is lazy; the network download is
not. Fully consuming events removes the temporary file. If enumeration stops
early, raises, or otherwise may not finish, call `FeedReader.close/1` in an
`after` block. Closing is safe after completion and can be repeated.

An ETag 304 or a matching previous checksum returns
`{:ok, :not_modified}` or `{:ok, :not_changed}` respectively, instead of a
session.

## Stream input chunks into a bounded result

`parse_stream/2` is different from `stream_file/2`: it takes XML chunks but
collects the result into memory, subject to `:max_items` and parser limits.
Chunks must be binaries.

```elixir
chunks = File.stream!("priv/feed.xml", 16_384, [:raw])
{:ok, result} = FeedReader.parse_stream(chunks, max_items: 500)
```

Chunk input is staged in a library-owned temporary file and cleaned up on
success and failure. Use `stream_file/2` when you want to process events
without collecting all items.

## Validate before exposing events

`stream_file_verified/2` and `stream_verified/2` validate the feed before
returning an event session. This is useful when consumers must not see any
events unless parsing succeeds. The validation pass adds work; delivery still
parses the source to emit events. `:max_parse_passes` bounds validation and
delivery passes and defaults to `5` (a value below `2` cannot allow both
passes).

```elixir
{:ok, session} = FeedReader.stream_file_verified("priv/feed.xml")
Enum.each(session.events, &process_event/1)
```

Verified remote sessions have the same temporary-file ownership rules as
`stream/2`: close them in `after` when enumeration may end early. Like the
other parser APIs, parsing stops when the feed root closes; trailing content
after a complete root is not parsed as part of the feed.
