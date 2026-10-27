# FeedReader

FeedReader fetches and parses RSS, Atom, and RDF feeds into normalized Elixir
data. It detects formats automatically, recovers from common defects in
real-world XML, and is tested against real feeds. Bounded results and lazy event
streams make it suitable for production workloads.

The [canonical repository](https://git.codeup.net/mmacia/feed_reader) is hosted
on Codeup. Copies on GitHub, GitLab, and other forges are mirrors for broader
distribution; project development and updates are maintained in the canonical
repository.

Add FeedReader to your Mix project's dependencies:

```elixir
defp deps do
  [
    {:feed_reader, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies and start an interactive Elixir session:

```sh
mix deps.get
iex -S mix
```

Try parsing a feed in IEx:

```elixir
xml = """
<rss version="2.0">
  <channel>
    <title>Example</title>
    <item><title>First item</title><guid>one</guid></item>
  </channel>
</rss>
"""

{:ok, result} = FeedReader.parse_binary(xml, max_items: 100)
result.feed.title
#=> "Example"

Enum.map(result.items, & &1.title)
#=> ["First item"]
```

## Fetch a remote feed

Use `fetch_and_parse/2` to download and collect a feed. Set `:max_items` to a
positive limit to bound the number of retained items.

```elixir
{:ok, result} =
  FeedReader.fetch_and_parse("https://example.com/feed.xml", max_items: 1_000)

result.feed
result.items
```

## Stream feed events

For large feeds, `stream/2` returns feed metadata and items as a lazy event
stream. Fully consuming the stream cleans up its downloaded temporary file. If
enumeration may stop early, close the session in an `after` block:

```elixir
{:ok, session} = FeedReader.stream("https://example.com/feed.xml")

try do
  session.events
  |> Enum.take(10)
  |> Enum.each(&IO.inspect/1)
after
  FeedReader.close(session)
end
```

Local feeds can be streamed with `stream_file/2`; the source file remains owned
by the caller. See the `FeedReader` module documentation for parsing options,
verified parsing, and format customization.

## How to contribute

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
