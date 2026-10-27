# Results and normalized data

FeedReader normalizes RSS, Atom, and RDF input into two structs:
`FeedReader.Feed` for feed-level metadata and `FeedReader.Item` for each entry.
Collection APIs wrap them in result structs; streaming APIs emit them as
events.

## Collection results

- `parse_file/2`, `parse_binary/2`, and `parse_stream/2` return
  `{:ok, %FeedReader.ParseResult{feed: feed, items: items}}`.
- `fetch_and_parse/2` returns
  `{:ok, %FeedReader.RemoteResult{feed: feed, items: items, fetch: fetch}}`.
- Both collection styles require a positive `:max_items` and return an error
  without partial data on failure.

Remote calls may instead return `{:ok, :not_modified}` after a conditional
HTTP 304 or `{:ok, :not_changed}` after a matching decoded-body checksum.
Those outcomes contain no parsed result.

## Stream events

The `events` enumerable in a `%FeedReader.Session{}` emits:

```elixir
{:feed, %FeedReader.Feed{}}
{:item, %FeedReader.Item{}}
{:error, reason}
```

Feed metadata is emitted before items. A parser failure is a terminal error
event; an error that prevents session creation is returned directly from the
API as `{:error, reason}`. See [Streaming and verified parsing](streaming.md)
for consumption and cleanup patterns.

## Feed fields

| Field | Meaning |
| --- | --- |
| `title` | Normalized feed title, with format-specific fallbacks. |
| `description` | Feed description or subtitle when present. |
| `feed_url` | Source URL. For remote parsing this defaults to the final response URL; local parsing defaults to `nil`. |
| `html_url` | Feed's website URL when available. |
| `type` | Built-in format: `:rss`, `:atom`, or `:rdf`. |
| `categories` | Unique category or subject strings. |
| `extensions` | Extension metadata keyed by namespace URI when retained by the format handler. |

## Item fields

| Field | Meaning |
| --- | --- |
| `uuid` | Source identifier, with a canonical URL fallback for some formats. |
| `title` | Normalized and, for RSS and Atom, sanitized title. |
| `content_full` | Full item content when supplied. |
| `content_summary` | Summary or description, sometimes falling back to title. |
| `language` | Language detected from a bounded sample of item text. |
| `published_at` | Parsed UTC `DateTime` when available. |
| `canonical_url` | Item URL; root-relative URLs are resolved against feed URLs. |
| `alternate` | Alternate links when exposed by a format handler. |
| `author` | Normalized author name when available. |
| `extensions` | Extension metadata keyed by namespace URI when retained by the format handler. |

Fields may be `nil` when the source does not provide a value. Format handlers
also have format-specific fallback behavior. For example, RDF currently uses
the current UTC time when its date is missing or invalid, while RSS and Atom
leave an unparseable date as `nil`.

## Common errors and limit behavior

Errors are returned as `{:error, reason}`. Common reasons include `:unknown`
for undetected or unregistered formats, `:invalid_url`, `:invalid_path`, HTTP
status errors, XML parser errors, and `{:resource_limit, option, limit}`.
Exact transport and parser reasons can depend on the underlying library.

Collection APIs require `:max_items`; exceeding it returns
`{:error, {:max_items_exceeded, max_items}}` without a partial result. The
limit controls retained item count, not downloaded bytes or total parsing work.
