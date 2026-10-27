# XML recovery

FeedReader normalizes a bounded set of common feed defects before passing XML
chunks to Saxy. The recovery pipeline is streaming and retains incomplete
markup across chunk boundaries, so output does not depend on chunk size.

Recovery is not a general-purpose XML repair tool. Other malformed documents
can still fail parsing.

## Supported recovery

- **Leading bytes:** Removes a UTF-8 BOM and XML whitespace before the XML
  declaration or root element.
- **Declared encodings:** Recognizes UTF-8 (the default), ISO-8859-1/Latin-1,
  and US-ASCII declarations. Latin-1 input is transcoded to UTF-8, and Latin-1
  and ASCII XML declarations are rewritten to `UTF-8` for the parser.
- **Entity references:** Preserves the five predefined XML entities and
  numeric references. Raw ampersands and invalid entity references are escaped.
  CDATA and comments are left unchanged.
- **Attribute quotes:** Repairs literal quote characters inside quoted
  attribute values by replacing them with `&quot;`. Valid empty attributes,
  comments, CDATA, and neighboring elements are preserved.

The recovery order is leading-prefix normalization, encoding conversion and
declaration normalization, entity normalization, then malformed-attribute
repair.

## Chunk handling

All recovery stages operate on enumerables without eagerly materializing the
whole feed. BOM bytes, declarations, entities, CDATA/comment delimiters, and
incomplete markup may be carried across chunk boundaries until enough input is
available to process them.

For example, a BOM split into separate one-byte chunks is handled the same as
one delivered in a single chunk. Changing `:chunk_size` does not change the
intended recovery result.

## Known boundaries

The encoding detector recognizes only the supported declarations; other
encodings default to UTF-8. Entity support is limited to predefined and numeric
XML references; unknown named references are escaped, not resolved. Quote
repair is confined to one complete markup element and does not attempt to
repair arbitrary broken tags or document structure. Recovery also does not
change format detection: detection still relies on the bounded source prefix.
