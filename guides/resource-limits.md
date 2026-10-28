# Resource limits

FeedReader parses XML incrementally, but it retains feed metadata, the current
item, pending stream events, and—when collecting—a list of items. Configure
limits for the resources that matter to your workload. These limits help avoid
memory or CPU spikes while parsing and make resource use more predictable across
feeds. Invalid values generally fall back to their defaults; the options below
accept non-negative integers unless noted.

## XML parsing limits

| Option | Default | Bounds |
| --- | ---: | --- |
| `:max_detection_bytes` | 65,536 bytes | Prefix inspected to detect a format; must be positive. |
| `:chunk_size` | 65,536 bytes | XML input chunks and SAX character-data callback sizing; must be positive. |
| `:max_xml_events` | 1,000,000 | SAX events processed. |
| `:max_xml_depth` | 256 | Nested XML element depth. |
| `:max_attributes_per_element` | 128 | Attributes on one element. |
| `:max_attribute_bytes` | 65,536 bytes | Combined name and value size of an individual attribute. |
| `:max_feed_metadata_bytes` | 1 MiB | Retained feed metadata. |
| `:max_item_bytes` | 4 MiB | Retained content for the current item. |
| `:max_queue_bytes` | Defaults to `:max_item_bytes` | Serialized size of one pending event. |

Zero is a valid limit for the non-negative resource budgets. A zero-byte
metadata or item budget, for example, rejects retained data in that scope.
Invalid XML-limit values use defaults. An invalid `:max_detection_bytes`
disables detection; supply a valid explicit `:format` to parse in that case.

## Application configuration

Set resource budgets globally with `:feed_reader, :options` and override them
for individual calls when needed:

```elixir
config :feed_reader, :options,
  max_items: 1_000,
  max_xml_depth: 128,
  max_compressed_bytes: 10_000_000

FeedReader.parse_file("priv/feed.xml", max_items: 100)
```

Per-call values take precedence over application config, which takes precedence
over built-in defaults. The application value must be a keyword list; malformed
values are ignored. `:feed_url`, `:previous_etag`, `:previous_checksum`, and
`:item_filter` are request-specific and cannot be set globally. See
`FeedReader` for the complete option-default reference.

Example for stricter parsing budgets:

```elixir
FeedReader.stream_file("priv/feed.xml",
  max_xml_events: 100_000,
  max_xml_depth: 64,
  max_attributes_per_element: 32,
  max_feed_metadata_bytes: 256_000,
  max_item_bytes: 1_000_000,
  max_queue_bytes: 1_000_000
)
```

Limit failures use the form `{:error, {:resource_limit, option, limit}}` from
collection APIs. In a stream, parsing errors are delivered as a terminal
`{:error, reason}` event.

## Remote download limits

Remote APIs accept these additional budgets:

| Option | Default | Bounds |
| --- | ---: | --- |
| `:max_compressed_bytes` | 50 MiB | Raw response bytes received. |
| `:max_decoded_bytes` | 50 MiB | Bytes after gzip/deflate decoding. |
| `:max_temp_bytes` | 50 MiB | Decoded bytes staged in the temporary file. |
| `:max_expansion_ratio` | 100 | Decoded-to-compressed byte ratio. |

The limits are checked while chunks are consumed. A failure removes any
temporary file created for the download. Content encodings supported by the
default pipeline are identity, gzip, and deflate; unsupported or stacked
encodings are rejected.

## Collection limits

`parse_file/2`, `parse_binary/2`, `parse_stream/2`, and `fetch_and_parse/2`
require a positive `:max_items`. The optional one-argument `:item_filter`
rejects items before they are counted and retained.

The item limit bounds retained item count, not input bytes, total parser work,
or network transfer. For remote feeds, the full response is downloaded before
parsing. Collection continues consuming parser events and returns no partial
result if an accepted item exceeds the item limit. Combine `:max_items` with
download and XML limits when you need those separate guarantees.

Verified APIs additionally accept `:max_parse_passes`, defaulting to `5`, to
bound validation and event-delivery passes. An invalid value uses the default.
