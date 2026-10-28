# FeedReader

FeedReader fetches and parses RSS, Atom, and RDF feeds into normalized Elixir
data. It detects formats automatically, recovers from a small set of common XML
defects, and offers bounded collection as well as lazy event streams.

The [canonical repository](https://git.codeup.net/mmacia/feed_reader) is hosted
on Codeup. Copies on GitHub, GitLab, and other forges are mirrors for broader
distribution; project development and updates are maintained in the canonical
repository.

## Installation

Add FeedReader to your Mix project's dependencies:

```elixir
defp deps do
  [
    {:feed_reader, "~> 0.1.0"}
  ]
end
```

## Quick start

Pass XML directly, or use `parse_file/2` for a local file. Collection APIs
require a positive `:max_items` limit:

```elixir
{:ok, result} = FeedReader.parse_file("priv/feed.xml", max_items: 500)

result.feed.title
Enum.map(result.items, & &1.title)
```

For a remote URL, `fetch_and_parse/2` downloads and collects the feed. Its
`:max_items` limit bounds the number of retained items; use the separate
download and parser limits when you also need to bound input size and parsing
resources. The default HTTP transport follows redirects automatically, up to
five; the final response URL is available in `result.fetch.final_url`.

```elixir
{:ok, result} =
  FeedReader.fetch_and_parse("https://example.com/feed.xml", max_items: 500)

result.feed.title
result.fetch.etag
```

## Application configuration

Set stable defaults in your application config. Per-call options override these
values, and both override FeedReader's built-in defaults:

```elixir
config :feed_reader, :options,
  max_items: 500,
  max_xml_depth: 128,
  http_retry_attempts: 3,
  formats: [MyApp.NoticeFormat],
  http_client: MyApp.FeedTransport
```

With `:max_items` configured, collection calls can omit it and use the shared
limit. A one-off call can override it:

```elixir
{:ok, result} = FeedReader.parse_file("priv/feed.xml")
{:ok, smaller_result} = FeedReader.parse_file("priv/feed.xml", max_items: 100)
```

Request-specific options such as `:feed_url`, `:previous_etag`,
`:previous_checksum`, and `:item_filter` must be supplied per call. See the
[resource limits guide](guides/resource-limits.md) and `FeedReader` API docs for
defaults and details. `:formats` adds custom formats after the built-ins;
`:http_client` selects a custom transport. Custom transports may define and read
their own additional options.

## Architecture

The public API coordinates a small pipeline:

1. Remote requests use a pluggable transport. The downloader consumes raw
   response chunks, decodes supported content encodings, enforces download
   budgets, computes a decoded-body checksum, and stages the result in an owned
   temporary file.
2. The parser inspects a bounded prefix to select RSS, Atom, RDF, or a supplied
   custom format. An explicit format can be selected when detection is
   unsuitable.
3. Streaming XML recovery normalizes supported encoding and markup defects
   before Saxy parses the input. Format handlers normalize metadata and items
   into `FeedReader.Feed` and `FeedReader.Item` values.
4. The parser emits `{:feed, feed}` and `{:item, item}` events. Streaming APIs
   expose those events lazily; collection APIs gather them into result structs
   under a finite item limit.

Remote streaming downloads before returning its session; event parsing then
reads the staged file lazily. A completed stream releases the temporary file.
If remote enumeration stops early, close the session with `FeedReader.close/1`.
Local sessions read caller-owned files and never remove them.

## Guides

- [Parsing and change detection](guides/usage.md) — files, binaries, streams,
  remote URLs, and unchanged-source checks.
- [Streaming and verified parsing](guides/streaming.md) — event lifecycle,
  cleanup, backpressure, and validation passes.
- [Resource limits](guides/resource-limits.md) — parser, download, and
  collection budgets.
- [Results and normalized data](guides/results.md) — result structs, events,
  normalized fields, and common outcomes.
- [Customization](guides/customization.md) — format detection, custom formats,
  transports, and HTTP behavior.
- [XML recovery](guides/xml-recovery.md) — supported repairs and their limits.

See the `FeedReader` module documentation for the complete API and option
reference.

## Contributing

Install [Elixir](https://elixir-lang.org/install.html) 1.20.4 with Erlang/OTP
29.1.2, as specified in `.tool-versions`. Then fetch dependencies and run the
project checks:

```sh
mix deps.get
mix precommit
mix credo --strict
```

Create a branch for your change and submit it as a pull request. `mix precommit`
compiles with warnings treated as errors, checks formatting, and runs the tests.
