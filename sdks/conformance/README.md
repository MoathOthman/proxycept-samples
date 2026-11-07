# Cross-SDK ingestion contract checks

These repository-owned fixtures exercise the same schema-version-1 admission
boundary across the source SDKs. They contain synthetic values only.

`attribute-vectors.json` covers scalar admission, inclusive numeric bounds,
invalid nested values and empty attribute names. A rejected candidate must not
discard a valid neighboring event. Sensitive accepted values must be redacted
before the first persistent write, not merely before upload.

SDK-specific suites additionally exercise UTF-8 byte limits, Unicode scalar
lengths, queue bounds/expiry, malformed or lost acknowledgements, replay IDs,
401/403 suspension, 413 adjustment, 429 Retry-After, network/5xx backoff,
concurrent lifecycle changes, storage errors and refused credential redirects.

Real-server smoke tests use a disposable local API and dedicated ingestion-only
credentials supplied in process memory/environment. Never commit test keys or
use a production service for these checks. A mock transport or native compile
alone does not prove device delivery; validation records distinguish those cases.
