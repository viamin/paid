# Mobile API contract

`openapi.yaml` is the schema-first contract for the Paid iOS companion. It is
hand-maintained alongside the endpoint implementation; do not regenerate it
from request specs, rswag, or routes. The iOS repository must pin the schema
to a Paid release tag or commit SHA, never a branch.

## Local checks

```bash
bundle exec rspec spec/lib/committee/drivers_mobile_inbox_contract_spec.rb
npx --yes @stoplight/spectral-cli@6.15.0 lint --fail-severity error docs/api/openapi.yaml
```

Committee validates mobile request and response bodies through
`config/initializers/committee.rb`: failures raise in test and warn without
interrupting requests in development and production.

To check Swift generation, copy the schema into the iOS package's configured
OpenAPI input and run its package plugin:

```bash
swift package generate-code-from-openapi
```

The iOS package owns generator configuration and generated source; this
repository owns only the published schema.

## Polling guidance

Poll `/api/v1/inbox/count` for badge updates and `/api/v1/inbox` only when a
refresh is needed. Preserve each response `ETag` and send it back in
`If-None-Match`; a `304` has no body and means the cached representation is
still current. Use exponential backoff with jitter for ordinary failures. On
`429`, honor `Retry-After` before retrying and use the unified
`error.code`/`error.details` envelope rather than parsing error text.

## Toolchain compatibility

The committed document currently uses OpenAPI 3.0.3 because Committee does
not support OpenAPI 3.1. Keep new constructs compatible with both Committee
and `swift-openapi-generator` until Committee gains 3.1 support; the
contract stays a single file for all consumers.
