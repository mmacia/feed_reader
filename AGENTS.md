# Agent notes

- Use the versions in `.tool-versions`: Elixir 1.20.4 (OTP 29) and Erlang 29.1.2.
- `mix precommit` is the project alias; it runs compile with warnings as errors,
  `deps.unlock --unused`, format check, then tests. It does not run Credo; run
  `mix credo --strict` separately when checking lint.
- Run a focused test with `mix test test/feed_reader/<name>_test.exs` (or pass a test
  line filter with `mix test path:line`). Test-only helpers and fake transports live
  in `test/support/` and are compiled only in the test environment.
- `FeedReader` is the public API. Parsing is event-stream based; built-in formats
  are tried in RSS, Atom, RDF order, and custom formats are supplied per call and
  implement `FeedReader.Format`.
- Remote stream sessions own downloaded temporary files. Fully consuming the event
  stream cleans them up; if enumeration stops early, call `FeedReader.close/1`
  (typically in `after`). Local-file sessions leave the caller's source file untouched.
