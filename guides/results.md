# Results and normalized data

FeedReader normalizes RSS, Atom, and RDF input into two structs:
`FeedReader.Feed` for feed-level metadata and `FeedReader.Item` for each entry.
Collection APIs wrap them in result structs; streaming APIs emit them as
events.

## Collection results

- `parse_file/2`, `parse_binary/2`, and `parse_stream/2` return
  `{:ok, %FeedReader.ParseResult{feed: feed, items: items,
  item_limit_reached?: limit_reached?}}`.
- `fetch_and_parse/2` returns
  `{:ok, %FeedReader.RemoteResult{feed: feed, items: items, fetch: fetch,
  item_limit_reached?: limit_reached?}}`.
- Collection gathers all accepted items by default. If an optional positive
  `:max_items` cap is reached, parsing stops and `item_limit_reached?` is `true`;
  the returned items may be only a prefix of the feed. If the cap is omitted,
  the field is `false`.

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
| `media` | Ordered image resources. RSS channel images and direct RDF channel image references become `:logo`; Atom feed icons and logos become `:icon` and `:logo`. Feed media is snapshotted before the first item, so later feed-level media is omitted; feeds without items use completed metadata. |
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
| `media` | Ordered image resources: RSS image enclosures, Atom image enclosure links, and external image content, plus Media RSS content and thumbnails in RSS, Atom, and RDF items. Other enclosure types, ordinary links, and media-like markup outside supported locations are omitted. |
| `author` | Normalized author name when available. |
| `extensions` | Extension metadata keyed by namespace URI when retained by the format handler. |

Fields may be `nil` when the source does not provide a value. Format handlers
also have format-specific fallback behavior. For example, RDF currently uses
the current UTC time when its date is missing or invalid, while RSS and Atom
leave an unparseable date as `nil`.

## Media values

Each `media` entry is a `%FeedReader.Media{}` with `url`, `kind`, `role`,
`mime_type`, `title`, `width`, and `height`. This increment extracts images only;
resources without a usable URL are omitted. Media RSS `content` is included only
when its image identity is clear, while thumbnails and format-defined image
resources use their element semantics. Image MIME types are normalized to
lowercase without parameters; invalid optional dimensions and metadata are `nil`.
URLs are trimmed. Single-slash root-relative URLs resolve against the feed's HTML
URL, then source URL; other relative and scheme-relative references remain as-is.
Entries preserve encounter order, including interleaved enclosure/content/
thumbnail types and a content element before its nested thumbnail.

| Role | Sources |
| --- | --- |
| `:content` | Image-identified Media RSS content; Atom external entry content with an image MIME type. |
| `:thumbnail` | Media RSS thumbnail elements, including grouped and content-nested thumbnails. |
| `:enclosure` | RSS image enclosures and Atom entry links with `rel="enclosure"` and an image MIME type. |
| `:icon`, `:logo` | Atom feed icon/logo; RSS channel image and direct RDF channel image reference are `:logo`. |

Media RSS content requires `medium="image"` with no type or an image type, or
an image type with no medium. Thumbnails follow their element semantics; their
MIME type is retained only when it identifies an image. Media is collected only
from the documented direct feed/item locations, not scraped from HTML or
unrelated extension markup.

## Common errors and limit behavior

Errors are returned as `{:error, reason}`. Common reasons include `:unknown`
for undetected or unregistered formats, `:invalid_url`, `:invalid_path`, HTTP
status errors, XML parser errors, and `{:resource_limit, option, limit}`.
Exact transport and parser reasons can depend on the underlying library.

Collection APIs accept an optional `:max_items` cap. When reached, collection
stops successfully with the items gathered so far and sets
`item_limit_reached?: true`; the rest of the feed is not checked for parse
errors. The cap controls retained item count, not downloaded bytes or input
staging. Without a cap, collection retains every accepted item.
