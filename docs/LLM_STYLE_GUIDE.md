# Paid LLM Style Cheat Sheet

> Concise rules for AI coding assistants working on Paid. Use this as the quick reference for generation. For rationale and examples, see `STYLE_GUIDE.md`.

## 1. Core Architecture

- **ZFC**: Meaning/decisions -> AI. Mechanical/structural -> code. Never hard-code semantic analysis. `STYLE_GUIDE:11-94`
- **AGD**: Use AI once at config time to generate deterministic artifacts; no AI calls at runtime. `STYLE_GUIDE:96-112`
- **Organize by capability** (parsers/, analyzers/, formatters/), not by workflow. `STYLE_GUIDE:113-161`
- **All LLM calls go through `agent_harness`** -- never call AI provider APIs directly. `STYLE_GUIDE:113-161`

### ZFC Decision Tree

```text
Analyzing meaning or making a judgment?
  YES -> Delegate to AI
  NO  -> Purely structural/mechanical?
    YES -> Keep in code
    NO  -> Probably needs AI
```

`STYLE_GUIDE:34-48`

## 2. Size & Complexity (Sandi Metz)

- Classes ~100 lines; Methods ~5 lines; Max 4 parameters; Controllers instantiate one object. `STYLE_GUIDE:165-186`
- These are guidelines, not laws -- break consciously when justified.
- Extract when a method does more than one thing or you're writing comments explaining a section. `STYLE_GUIDE:188-203`
- Don't extract when it just moves complexity or creates coupling. `STYLE_GUIDE:188-203`

## 3. Service Objects (Servo)

- Business logic lives in Servo service objects, not models or controllers. `STYLE_GUIDE:205-269`
- Declarative inputs/outputs with type checking, built-in validations, consistent result interface. `STYLE_GUIDE:209-269`
- Namespace by domain, verb-noun naming: `AgentRuns::Create`, `Projects::Import`. `STYLE_GUIDE:333-362`

## 4. Ruby Conventions

- Follow StandardRB. `frozen_string_literal: true` on all files. `STYLE_GUIDE:366-380`
- `require_relative` over `require` for local files. `STYLE_GUIDE:366-380`
- No `get_`/`set_` prefixes. Avoid boolean flag parameters -- split methods instead. `STYLE_GUIDE:366-380`
- No commented-out code. No TODO without issue reference: `# TODO(#123): desc`. `STYLE_GUIDE:366-380`
- Convert to UTF-8 before regex/string operations on external input. `STYLE_GUIDE:382-394`

### Database

- UUIDs for external-facing IDs, bigints for internal FKs. `STYLE_GUIDE:396-406`
- Always add foreign key constraints and index FK columns. `STYLE_GUIDE:396-406`
- Prefer `timestamp` over `datetime`. Prefer explicit columns over JSON for queryable data. `STYLE_GUIDE:396-406`

### Naming

- Services: `VerbNoun` (`CreateProject`). Jobs: `NounVerbJob` (`AgentRunCleanupJob`). `STYLE_GUIDE:408-437`
- Workflows: `NounWorkflow`. Activities: `VerbNounActivity`. Adapters: `ServiceNameAdapter`. `STYLE_GUIDE:408-437`

## 5. Structured Logging

- JSON structured logging with consistent component names. `STYLE_GUIDE:439-682`
- `Rails.logger.{debug|info|warn|error}(message: "component.action", **metadata)` `STYLE_GUIDE:560-648`
- **Always include**: correlation IDs, counts/sizes, timing, status codes. `STYLE_GUIDE:650-666`
- **Never include**: secrets, full payloads, PII, redundant info. `STYLE_GUIDE:650-666`
- Components: `agent_execution`, `github_sync`, `prompt_evolution`, `container_manager`, `temporal_worker`, `model_selection`, `secrets_proxy`. `STYLE_GUIDE:668-682`

### Log Levels

| Level | Use For |
|-------|---------|
| `debug` | Method calls, internal state, decision points |
| `info` | Significant events, completions, user actions, state transitions |
| `warn` | Rate limits, fallbacks, retries, degraded functionality |
| `error` | Failures, exceptions, security events |

`STYLE_GUIDE:453-542`

## 6. Testing

- Test behavior/interfaces, not implementation. `STYLE_GUIDE:686-715`
- Focus on message types (Sandi Metz): assert incoming queries/commands, mock outgoing commands, don't test private methods. `STYLE_GUIDE:686-715`
- Clear test descriptions and descriptive `context` blocks. `STYLE_GUIDE:717-723`
- One spec file per class, path mirrors class path. `STYLE_GUIDE:725-763`
- Mock ONLY external dependencies, never application code. `STYLE_GUIDE:765-803`
- **No test logic in production code** -- use dependency injection. `STYLE_GUIDE:765-803`
- **No `sleep` in tests** -- use deterministic timestamps. `STYLE_GUIDE:805-840`
- Target 85-100% coverage for business logic. `STYLE_GUIDE:842-858`

### Pending Specs (Strict)

| Case | Allowed? |
|------|----------|
| Regression (was green) | No -- fix or remove |
| Planned future work | Yes -- with issue ref |
| Flaky external dep | Caution -- with issue + retry plan |

`STYLE_GUIDE:860-878`

## 7. Error Handling

- **Internal errors**: Let them crash (bugs should surface immediately). `STYLE_GUIDE:882-888`
- **External errors**: Handle gracefully with specific error types. `STYLE_GUIDE:890-930`
- Never use generic `rescue => e`. Create specific error classes per failure mode. `STYLE_GUIDE:890-930`
- Use Temporal retry policies for transient failures; mark non-retryable errors. `STYLE_GUIDE:932-960`

## 8. Rails Patterns

- **Controllers**: Thin, delegate to services. HTTP concerns only. `STYLE_GUIDE:964-1001`
- **Views**: Phlex components (pure Ruby, composable, performant). `STYLE_GUIDE:1003-1121`
- **Hotwire**: Broadcast Turbo Stream updates via Phlex rendering. `STYLE_GUIDE:1123-1142`
- **Background jobs**: Prefer Temporal workflows for multi-step/external work. GoodJob for simple fire-and-forget. `STYLE_GUIDE:1144-1193`

## 9. Security

- Never execute untrusted code outside containers. `STYLE_GUIDE:1197-1206`
- Validate file paths to prevent directory traversal. `STYLE_GUIDE:1208-1222`
- Don't log secrets -- redaction is a safety net, not primary defense. `STYLE_GUIDE:1224-1240`

## 10. Backward Compatibility

- **Pre-release (v0.x.x): No backward compatibility.** `STYLE_GUIDE:1242-1257`
- Remove old implementations immediately. No legacy wrappers, feature flags, or deprecated methods.
- Update all callers in the same commit.

## 11. Concurrency & Threads

- Always clean up threads in `ensure` blocks. `STYLE_GUIDE:1259-1302`
- Avoid global mutable state without synchronization. `STYLE_GUIDE:1259-1302`
- Make intervals configurable for testing. `STYLE_GUIDE:1259-1302`

## 12. Performance

- Avoid O(n^2) -- use index lookups over nested loops. `STYLE_GUIDE:1306-1321`
- Batch database operations. Use `find_each` for large record sets. `STYLE_GUIDE:1323-1343`
- Stream large files. Cache expensive operations with invalidation strategy. `STYLE_GUIDE:1345-1375`

## 13. Code Review Checklist

- [ ] Classes ~100 lines, methods ~5 lines, max 4 params
- [ ] Tests are behavior-focused with clear descriptions
- [ ] Specific error types, not generic rescue
- [ ] Only external deps mocked
- [ ] No ZFC violations
- [ ] No backward compat shims or "legacy" methods
- [ ] No secrets in logs
- [ ] No N+1 queries
- [ ] No `sleep` in tests

`STYLE_GUIDE:1378-1390`

## 14. Anti-Patterns (Reject in PRs)

- Regex/keyword matching for semantic meaning
- Hard-coded scoring formulas or heuristic thresholds
- Mocking application code in tests
- Mock/test logic in production code
- Pending regressions (was green, now pending)
- God methods or god classes
- Silent exception swallowing
- Backward compatibility wrappers

---
**Use this cheat sheet for quick reference; consult `STYLE_GUIDE.md` when context or rationale is needed.**
