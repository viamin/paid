# Ecosystem Certification

Paid's ecosystem catalog supports three support tiers and four certification states so customers can distinguish community extensions from partner-supported and first-party offerings.

## Support Tiers

- `community`: Shared by a customer or maintainer with no Paid support commitment.
- `partner`: Supported by a named implementation or technology partner.
- `first_party`: Built and supported directly by Paid.

## Certification States

- `uncertified`: Cataloged, but not yet reviewed against the checklist below.
- `self_attested`: The publisher completed the checklist and attached evidence.
- `verified`: A Paid operator or designated reviewer validated the evidence.
- `certified`: Verified and approved for repeatable production use.

## Certification Checklist

- Installation and rollback steps are documented.
- Supported extension points are declared explicitly.
- Runtime and compatibility constraints are recorded.
- Ownership, escalation path, and support boundary are documented.
- Security-sensitive behavior, scopes, and secrets handling are described.
- A smoke test or verification procedure exists for upgrades.
- Failure modes and safe-disable guidance are documented.

## Required Catalog Metadata

- `entry_type` identifies the distribution shape, such as `integration`, `policy_pack`, or `workflow_strategy`.
- `extension_points` identifies which Paid contracts the entry targets.
- `support_tier` communicates who owns support.
- `certification_status` communicates review depth.
- `documentation_url` and `source_code_url` provide operator traceability.
- `certification_notes` summarizes evidence, gaps, or rollout caveats.
