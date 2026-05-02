# Changelog

## [0.36.0](https://github.com/viamin/paid/compare/v0.35.0...v0.36.0) (2026-05-02)


### Features

* add chat container manager for workspace sessions ([#1520](https://github.com/viamin/paid/issues/1520)) ([cd70a99](https://github.com/viamin/paid/commit/cd70a997f53c4795cb765469a8882f02ee8bdc3b))
* add Paid MCP server for agent tool use ([#1532](https://github.com/viamin/paid/issues/1532)) ([794bb41](https://github.com/viamin/paid/commit/794bb412d180c93cc57331d981c3945ddb49f667))


### Bug Fixes

* **agent-runs:** cache distinct_effective_providers to eliminate full-table scan on index page ([#1586](https://github.com/viamin/paid/issues/1586)) ([4516744](https://github.com/viamin/paid/commit/4516744188af7c3356fe02d55e8ff26c614c2f8a))
* Auth failure checker false positives on rate-limit 403s and infrastructure 503s ([#1592](https://github.com/viamin/paid/issues/1592)) ([3bc154d](https://github.com/viamin/paid/commit/3bc154d40e8a4930d472ee939462ec190ce3b886))
* Circuit breaker record_success! race condition allows overwriting open state ([#1594](https://github.com/viamin/paid/issues/1594)) ([f61ad25](https://github.com/viamin/paid/commit/f61ad2525f0324198894a090e142879b373d4561))
* **projects:** defer expensive dashboard cost snapshots ([#1580](https://github.com/viamin/paid/issues/1580)) ([e556b3e](https://github.com/viamin/paid/commit/e556b3e76ed69db9d529cc06e202118bb21c6b60))
* Provider validation missing at agent run creation time ([#1593](https://github.com/viamin/paid/issues/1593)) ([6f6d8e7](https://github.com/viamin/paid/commit/6f6d8e72748a6cc62d80d7088180f16ca411cdd2))

## [0.35.0](https://github.com/viamin/paid/compare/v0.34.0...v0.35.0) (2026-05-01)


### Features

* add centralized exception handling service with auto-issue filing and self-healing ([#1531](https://github.com/viamin/paid/issues/1531)) ([542d96b](https://github.com/viamin/paid/commit/542d96b82dc02739095631d5dd99545845d009f0))


### Bug Fixes

* **agent-runs:** prevent false-positive quota error on substantial agent output ([#1581](https://github.com/viamin/paid/issues/1581)) ([4c346e9](https://github.com/viamin/paid/commit/4c346e95ba07e5aa9363d4c424541364005cbd80))
* Heartbeat disabled for Docker volume workspaces causes idle timeout false positives ([#1584](https://github.com/viamin/paid/issues/1584)) ([138ab90](https://github.com/viamin/paid/commit/138ab908104d6ef2947c33cd4e55a8d90dd76f3c))
* Projects permanently stuck in scheduler_paused after token re-validation ([#1579](https://github.com/viamin/paid/issues/1579)) ([2e7e818](https://github.com/viamin/paid/commit/2e7e818eb7a2f9aa96cb5b784968f39234e9bfa1))
* **providers:** generate record-format provider in kilocode and opencode CLI configs ([#1585](https://github.com/viamin/paid/issues/1585)) ([0d98d94](https://github.com/viamin/paid/commit/0d98d9459f5ec3030aff80bc1092138b5d65fa61))

## [0.34.0](https://github.com/viamin/paid/compare/v0.33.0...v0.34.0) (2026-04-30)


### Features

* add chat API endpoints with SSE streaming ([#1523](https://github.com/viamin/paid/issues/1523)) ([a814edf](https://github.com/viamin/paid/commit/a814edf32d9ea4c924eaa337a032835ac98a8476))
* add chat cost tracking and limits ([#1522](https://github.com/viamin/paid/issues/1522)) ([b444bee](https://github.com/viamin/paid/commit/b444beedb01f90f64bbbe02a5f38c30e39836cc1))
* add chat system prompt and context injection ([#1521](https://github.com/viamin/paid/issues/1521)) ([789a30b](https://github.com/viamin/paid/commit/789a30b140791a6760ee7b8b9024a412f00fb1ef))
* **knowledge:** create KnowledgeEvolutionJob, workflow, and activities ([#1524](https://github.com/viamin/paid/issues/1524)) ([7c24871](https://github.com/viamin/paid/commit/7c2487101eaac6de9b62c735cc50aa6eed739428))
* **performance:** ungate CI performance benchmarks and improve reliability ([#1559](https://github.com/viamin/paid/issues/1559)) ([d088349](https://github.com/viamin/paid/commit/d08834944553ec4db6a6fe35cac70dc094bba9b3))
* **test:** add fixture-kit and test-prof profiling ([#1560](https://github.com/viamin/paid/issues/1560)) ([6664e8f](https://github.com/viamin/paid/commit/6664e8f49d9697e3114a91c5f716ad317161998c))


### Bug Fixes

* **agent-runs:** extend idle timeout for providers with coarse heartbeat signals ([#1572](https://github.com/viamin/paid/issues/1572)) ([94a1d93](https://github.com/viamin/paid/commit/94a1d93e4262509c18e41a6fbebded61552e83cc))
* **agent-runs:** improve provider fallback diagnostics ([#1577](https://github.com/viamin/paid/issues/1577)) ([e1eeb7d](https://github.com/viamin/paid/commit/e1eeb7d81bb0495b7a208fe87ac417ed1e16aa43))
* **agent-runs:** improve timeout observability, extend abort to stdout, fix auth lock contention ([#1568](https://github.com/viamin/paid/issues/1568)) ([f4d5b72](https://github.com/viamin/paid/commit/f4d5b729c76476d3eadcfdfef46158162e1c82a9))
* **agent-runs:** remove hardcoded Claude preference from provider fallback paths ([#1551](https://github.com/viamin/paid/issues/1551)) ([48ddd4a](https://github.com/viamin/paid/commit/48ddd4abf05ece8f26532bf5339373d9b5651f87))
* **auto-pick:** order equal-priority issues oldest-first instead of newest-first ([#1526](https://github.com/viamin/paid/issues/1526)) ([86921d9](https://github.com/viamin/paid/commit/86921d9697f4fe833f00bd809ee5fef617507f49))
* **containers:** mount host-visible heartbeat directory into container ([#1558](https://github.com/viamin/paid/issues/1558)) ([01701e1](https://github.com/viamin/paid/commit/01701e1335175b6ae23b21d893d896e057a21f64))
* **devcontainer:** remove redundant PG 15 feature and add pg_dump to agent container ([#1534](https://github.com/viamin/paid/issues/1534)) ([93c7515](https://github.com/viamin/paid/commit/93c7515bf5bd7be5a63719540bc39d78cd70042d))
* **github-tokens:** broadcast validation state instead of polling ([#1529](https://github.com/viamin/paid/issues/1529)) ([9131e0d](https://github.com/viamin/paid/commit/9131e0d5fb91031c2eb99f62484342056ce54bcf))
* **kilocode:** inject PAID_KILOCODE_CONFIG_B64 into container env for direct-outbound providers ([#1571](https://github.com/viamin/paid/issues/1571)) ([4e06484](https://github.com/viamin/paid/commit/4e064843295a99dbecf6e16fc9867125a7239e53))
* **kilocode:** resolve test-agent timeout for kilocode providers with direct-outbound API keys ([#1570](https://github.com/viamin/paid/issues/1570)) ([8dd72bf](https://github.com/viamin/paid/commit/8dd72bf073f4ac4612f560b2087b0adc6dc4affd))
* **notifications:** fix Pagy pagination crash and mark-all-read UX ([#1536](https://github.com/viamin/paid/issues/1536)) ([8835804](https://github.com/viamin/paid/commit/88358042f4505fd11c792f64121aa5097a299e1c))
* **opencode:** pre-seed opencode database into container tmpfs ([#1539](https://github.com/viamin/paid/issues/1539)) ([e6b2e6e](https://github.com/viamin/paid/commit/e6b2e6efbf172eeebe181b629c142f8bfc7d86c8))
* **tests:** stabilize request-spec tenant context ([#1573](https://github.com/viamin/paid/issues/1573)) ([8471014](https://github.com/viamin/paid/commit/84710143ccf0cd78b64421503198a5c738b2bc59))
* Watchdog thread dies silently on unexpected exceptions ([#1554](https://github.com/viamin/paid/issues/1554)) ([f82be06](https://github.com/viamin/paid/commit/f82be06971eb3b2d9df4fd12d51d7a19597d61cc))

## [0.33.0](https://github.com/viamin/paid/compare/v0.32.0...v0.33.0) (2026-04-28)


### Features

* add chat session service layer ([#1514](https://github.com/viamin/paid/issues/1514)) ([ef68dcb](https://github.com/viamin/paid/commit/ef68dcb2f2f167b0d3276cf32394a8796cf0cccb))
* add chat sessions and messages database schema ([#1485](https://github.com/viamin/paid/issues/1485)) ([f9b2234](https://github.com/viamin/paid/commit/f9b2234d7d61ded4018d6afcb9f50411ebfed22d))
* **agent-runs:** add GitHub circuit breaker to pause dispatching during outages ([#1502](https://github.com/viamin/paid/issues/1502)) ([07f4afb](https://github.com/viamin/paid/commit/07f4afbbec1e0c5a03758159df35090683f92e9a))
* **agent-runs:** intelligent model selection based on task complexity ([#1511](https://github.com/viamin/paid/issues/1511)) ([b24881c](https://github.com/viamin/paid/commit/b24881cf48a3c427f40a1b52249ff99b6a5845c6))
* **auto-merge:** extract auto-merge into strategy module ([#1120](https://github.com/viamin/paid/issues/1120)) ([#1510](https://github.com/viamin/paid/issues/1510)) ([ee70c6a](https://github.com/viamin/paid/commit/ee70c6a62326ef2443ea727eef84617b7b33d3ec))
* **dashboard:** move active runs above queue health in live view ([#1499](https://github.com/viamin/paid/issues/1499)) ([8a6df10](https://github.com/viamin/paid/commit/8a6df10e1d90233e2dea1d61e1947b2f7a4c1a8b))
* **dependabot:** evaluate auto-merge from poll loop so webhooks are optional ([#1482](https://github.com/viamin/paid/issues/1482)) ([b29ec8a](https://github.com/viamin/paid/commit/b29ec8a64c1e50dc442dd1306ce0363cbc6e7f50))
* **github-tokens:** add periodic token health check job ([#1503](https://github.com/viamin/paid/issues/1503)) ([c6dc8eb](https://github.com/viamin/paid/commit/c6dc8eb3f9dca9146d9953440472a17271667dcd))
* **github-tokens:** trigger focused token validation on auth-related run failures ([#1506](https://github.com/viamin/paid/issues/1506)) ([6112c55](https://github.com/viamin/paid/commit/6112c5547fcad775ac618b985a3875920dd8e81e))
* **knowledge:** add Knowledge::UsageStats service and dashboard integration ([#1504](https://github.com/viamin/paid/issues/1504)) ([1f497e3](https://github.com/viamin/paid/commit/1f497e3c2c67140e0fe583ca54930fda9b4a230e)), closes [#1418](https://github.com/viamin/paid/issues/1418)
* **knowledge:** add KnowledgeRecommendation model and knowledge_evolution_enabled project setting ([#1513](https://github.com/viamin/paid/issues/1513)) ([3430b38](https://github.com/viamin/paid/commit/3430b387d569ff1e94a6dd1e08138aa7b653c178))
* **knowledge:** add schema/data model collector ([#1467](https://github.com/viamin/paid/issues/1467)) ([9d6c2e9](https://github.com/viamin/paid/commit/9d6c2e9fa8efb2621078ccebde18216da3de0bd7))
* **knowledge:** instrument ContextBundle::Build and Knowledge::Search with agent_run tracking ([#1461](https://github.com/viamin/paid/issues/1461)) ([5275bab](https://github.com/viamin/paid/commit/5275bab80886099697b22c41eacb56866721a3e7))
* **projects:** auto-pause projects when GitHub token is confirmed expired ([#1505](https://github.com/viamin/paid/issues/1505)) ([c5b0c59](https://github.com/viamin/paid/commit/c5b0c59d6da69bd8b334c124fd155b03f13791c7))
* **prompts:** add data-driven CI failure debugging guidance ([#1489](https://github.com/viamin/paid/issues/1489)) ([4eb1752](https://github.com/viamin/paid/commit/4eb1752a8826c22e08d0937d4d2c026a421893ba))
* **providers:** simplify agent-run provider selection into single mode selector ([#1456](https://github.com/viamin/paid/issues/1456)) ([#1508](https://github.com/viamin/paid/issues/1508)) ([e339a67](https://github.com/viamin/paid/commit/e339a67a1591772baff5720a7562ab4b120716bc))
* **quality:** add quality metrics for secondary LLM outputs (PR descriptions, issue titles, decision records) ([#1458](https://github.com/viamin/paid/issues/1458)) ([b3a6325](https://github.com/viamin/paid/commit/b3a6325cd83ddaa68969caf2f88faf7a7ff44f2f))
* **ux:** show in-progress phase in agent run timeline ([#1509](https://github.com/viamin/paid/issues/1509)) ([357c1e9](https://github.com/viamin/paid/commit/357c1e9b731b9b871a81fc57e57b43d2a2fcf591))


### Bug Fixes

* 1121: Extract auto-continue into strategy modules ([#1515](https://github.com/viamin/paid/issues/1515)) ([f2e4535](https://github.com/viamin/paid/commit/f2e453547d72cc6621e32522c7cf9adc9e34e418))
* 1318: Add provider-contract smoke test for paid-agent image ([#1487](https://github.com/viamin/paid/issues/1487)) ([974f3fe](https://github.com/viamin/paid/commit/974f3fe747b9f2e1c41a33feebaaae56c0466ea0))
* 1321: Fix PR escalation dismissal UX and reset operational retry boundary ([#1481](https://github.com/viamin/paid/issues/1481)) ([00e1242](https://github.com/viamin/paid/commit/00e1242903023cec783c42ecf5c2f73df0a56572))
* 1327: Create-issue runs should deterministically apply selected priority labels ([#1486](https://github.com/viamin/paid/issues/1486)) ([48664a8](https://github.com/viamin/paid/commit/48664a8fef459d980a4c74e6091501457ed1abeb))
* 1330: Make the Knowledge page browsable and project-scoped ([#1488](https://github.com/viamin/paid/issues/1488)) ([b2d0802](https://github.com/viamin/paid/commit/b2d0802f83418ba948f635cce410d2dd95a6a40a))
* 1399: Retry transient CI failures before starting another agent run ([#1500](https://github.com/viamin/paid/issues/1500)) ([240aad5](https://github.com/viamin/paid/commit/240aad5f26c7c20c41570a0ac20c3eef4bd2c470))
* 1438: Dashboard shows paused/failure context that Agent Run detail page does not surface consistently ([#1507](https://github.com/viamin/paid/issues/1507)) ([7b9506e](https://github.com/viamin/paid/commit/7b9506edb5a8f36cf223ec8eadc7598a0956b8d6))
* **agent-runs:** add row locking to fail! and cancel! for race condition safety ([#1501](https://github.com/viamin/paid/issues/1501)) ([bfdd69e](https://github.com/viamin/paid/commit/bfdd69ec27b6d666fae7d91ac05ec558334fbe36)), closes [#1394](https://github.com/viamin/paid/issues/1394)
* **agent-runs:** mount /tmp tmpfs with exec so bundle install can build native gems ([#1497](https://github.com/viamin/paid/issues/1497)) ([be5b142](https://github.com/viamin/paid/commit/be5b142ab42edcf8eea237c1184138b454615ba6))
* **cost-dashboard:** label token usages by provider when model id is absent ([#1519](https://github.com/viamin/paid/issues/1519)) ([8d00088](https://github.com/viamin/paid/commit/8d00088d741ba94d4670a6e72ecd30e12512cf39))
* **knowledge:** prevent TypeError from nil artifact_count in schema section ([#1498](https://github.com/viamin/paid/issues/1498)) ([97da6d0](https://github.com/viamin/paid/commit/97da6d010dab0fb766f8fe47d7e3d1c7ed3ca51d))
* **pr-descriptions:** use agent summary as fallback when LLM generation fails ([#1496](https://github.com/viamin/paid/issues/1496)) ([40ea48c](https://github.com/viamin/paid/commit/40ea48c1d9ba2453a84122c28a11732ddf5a6c7c))
* **pr-scanner:** rescan ready/escalated PRs when auto-merge is enabled ([#1528](https://github.com/viamin/paid/issues/1528)) ([9f15164](https://github.com/viamin/paid/commit/9f151646c93d6fd270727f557913a76963a32695))
* **security:** surface code scanning 403 permission errors instead of silently failing ([#1483](https://github.com/viamin/paid/issues/1483)) ([32ed9b5](https://github.com/viamin/paid/commit/32ed9b5bd277ff427517e93f2d86057c4f43a517))
* **ui:** show Cancel and Resume buttons for paused agent runs ([#1477](https://github.com/viamin/paid/issues/1477)) ([6a8d1d2](https://github.com/viamin/paid/commit/6a8d1d258d4481fcae98f39b7a9951ef230f2cef))


### Performance Improvements

* defer heavy gem loading and fix initializer reload correctness ([#1491](https://github.com/viamin/paid/issues/1491)) ([8422b70](https://github.com/viamin/paid/commit/8422b7045b7af6398f23a2a51a5c8a669ab2eaed))

## [0.32.0](https://github.com/viamin/paid/compare/v0.31.0...v0.32.0) (2026-04-26)


### Features

* **auto-pick:** integrate analyze_issue gate into auto-pick strategy ([#1475](https://github.com/viamin/paid/issues/1475)) ([ae59183](https://github.com/viamin/paid/commit/ae59183f8c9c908f9958ad0c7125c39013017d2a)), closes [#1415](https://github.com/viamin/paid/issues/1415)
* **providers:** display per-provider usage stats on /providers page ([#1470](https://github.com/viamin/paid/issues/1470)) ([ec7640b](https://github.com/viamin/paid/commit/ec7640bbbff0501a1a6bdc70179447cdc66fc1ca))


### Bug Fixes

* **auth:** restore login by deferring Warden auth until after CSRF check ([#1473](https://github.com/viamin/paid/issues/1473)) ([df6782c](https://github.com/viamin/paid/commit/df6782cd4b3f6035d47fe3ef84bf3535b57bec41))
* **prompt-evolution:** persist prompt_version_id for goal-augmented runs ([#1480](https://github.com/viamin/paid/issues/1480)) ([56675c9](https://github.com/viamin/paid/commit/56675c93f162ba4520c6c56cbc3c85bc8c38c18a)), closes [#1324](https://github.com/viamin/paid/issues/1324)
* **providers:** upgrade agent-harness to 0.11.0 for GitHub Copilot CLI fix ([#1313](https://github.com/viamin/paid/issues/1313)) ([#1479](https://github.com/viamin/paid/issues/1479)) ([9d7d63e](https://github.com/viamin/paid/commit/9d7d63e5f1e72ecb12f1b8b47cf99fd00f636a92))

## [0.31.0](https://github.com/viamin/paid/compare/v0.30.0...v0.31.0) (2026-04-26)


### Features

* **agent-runs:** create AgentRuns::CreateFollowup service for post-analysis routing ([#1469](https://github.com/viamin/paid/issues/1469)) ([b2675c1](https://github.com/viamin/paid/commit/b2675c1d8a2b8d9373b97a49c2e7a271d82dfd97)), closes [#1414](https://github.com/viamin/paid/issues/1414)
* **agent-runs:** escalate to higher model tier when quality scores are low ([#1450](https://github.com/viamin/paid/issues/1450)) ([5639064](https://github.com/viamin/paid/commit/563906423a11d60da9b67ea3181fda729a8b278d))
* **dashboards:** surface tier usage and tier-vs-quality metrics ([#1455](https://github.com/viamin/paid/issues/1455)) ([093a15a](https://github.com/viamin/paid/commit/093a15a8eecc118aa15ae99bf9d3960980718da8))
* **evolution:** extend A/B testing to non-prompt configuration experiments ([#1410](https://github.com/viamin/paid/issues/1410)) ([ef6f68c](https://github.com/viamin/paid/commit/ef6f68c6b9414012c4158ece23f536b313e5e440))
* **infrastructure:** expose Flipper percentage rollout and add progressive deployment UI ([#1460](https://github.com/viamin/paid/issues/1460)) ([0d505ee](https://github.com/viamin/paid/commit/0d505ee734d359d34c817494252cc88415afdb6e))
* **knowledge:** add  project setting and  goal scaffolding ([#1453](https://github.com/viamin/paid/issues/1453)) ([3884ee6](https://github.com/viamin/paid/commit/3884ee6c1fe5c94b5caca5268af23d85ce0575e6))
* **knowledge:** add KnowledgeUsageStat model for per-artifact-type usage tracking ([#1448](https://github.com/viamin/paid/issues/1448)) ([136d8f0](https://github.com/viamin/paid/commit/136d8f06683d52f3de4254c5087909d6068eb131))
* **monitoring:** operational alert rules for stalled PRs, runaway loops, quota exhaustion ([#1451](https://github.com/viamin/paid/issues/1451)) ([75a2fc0](https://github.com/viamin/paid/commit/75a2fc091ece3b353322273e3ab465ec8887c723))
* **quality:** auto-unpause projects after quality recovery or prompt evolution ([#1405](https://github.com/viamin/paid/issues/1405)) ([fd8b662](https://github.com/viamin/paid/commit/fd8b6627576d26213756aab2be41a5441fac1e7d))
* **quality:** quality pause should trigger targeted prompt evolution ([#1406](https://github.com/viamin/paid/issues/1406)) ([8f19e5f](https://github.com/viamin/paid/commit/8f19e5f0f36994024860b9648f6b5d55e903a280))
* **quality:** replace auto-pause with auto-improve cycle ([#1409](https://github.com/viamin/paid/issues/1409)) ([7e0a62e](https://github.com/viamin/paid/commit/7e0a62e0e6aa7ea00197d1aab79b6f25dbb50cda))
* **quality:** try different models before pausing on quality drop ([#1407](https://github.com/viamin/paid/issues/1407)) ([51031c6](https://github.com/viamin/paid/commit/51031c616110d378a78471002938c3b3e205d9b6))
* **release:** evaluate auto-release from poll loop so webhooks are optional ([#1464](https://github.com/viamin/paid/issues/1464)) ([277c724](https://github.com/viamin/paid/commit/277c724a8fb51bbd3a8b481e3c032953c2e936a7))
* **scheduler:** add cross-user fair queueing ([#1275](https://github.com/viamin/paid/issues/1275)) ([#1459](https://github.com/viamin/paid/issues/1459)) ([32830f0](https://github.com/viamin/paid/commit/32830f02cf2d309953ff9b009db013c17b520792))
* **settings:** move worker concurrency and self-repo config to TenantSetting ([#1465](https://github.com/viamin/paid/issues/1465)) ([c85d935](https://github.com/viamin/paid/commit/c85d93506afc9d941fbcc097e6e0428cc1d5ce21))
* **temporal:** create AnalyzeIssueActivity for context readiness assessment ([#1468](https://github.com/viamin/paid/issues/1468)) ([c8a6d3e](https://github.com/viamin/paid/commit/c8a6d3e4cc34ec7a210616e23a7d3dd367102073)), closes [#1413](https://github.com/viamin/paid/issues/1413)


### Bug Fixes

* 1255: dev-update: deadlocks when working tree has unstaged changes ([#1454](https://github.com/viamin/paid/issues/1454)) ([8fb8878](https://github.com/viamin/paid/commit/8fb88781d764e2519848e5ab1bf19572f68b4d74))
* 847: Add truncation with expand/collapse for long log output on agent run page ([#1449](https://github.com/viamin/paid/issues/1449)) ([bffbaa7](https://github.com/viamin/paid/commit/bffbaa7f744fb36ec65485d96909c91250cdb15f))
* **agent-runs:** record harness token usage from containers ([#1403](https://github.com/viamin/paid/issues/1403)) ([a3a9a93](https://github.com/viamin/paid/commit/a3a9a93d4d04717439e609350fd8025403893b0f))
* **dev-update:** use actual pull diff for restart decision instead of trigger context ([#1452](https://github.com/viamin/paid/issues/1452)) ([2677a43](https://github.com/viamin/paid/commit/2677a43177fcbebdf817f1c2f4e22144ae08627a)), closes [#1254](https://github.com/viamin/paid/issues/1254)
* **knowledge:** reduce periodic slowdowns from synchronized collection bursts ([#1443](https://github.com/viamin/paid/issues/1443)) ([e21d1db](https://github.com/viamin/paid/commit/e21d1dbbd6c561619a436fc5422566625508646c))
* **service-containers:** align service and agent Docker networks for direct-outbound runs ([#1462](https://github.com/viamin/paid/issues/1462)) ([ea9822b](https://github.com/viamin/paid/commit/ea9822bc72a54e8c90111b2f54a2b2c2b217b15b))

## [0.30.0](https://github.com/viamin/paid/compare/v0.29.0...v0.30.0) (2026-04-25)


### Features

* **ab-tests:** wire A/B test assignment into live agent execution ([#1362](https://github.com/viamin/paid/issues/1362)) ([79daa6f](https://github.com/viamin/paid/commit/79daa6f9244c9b8e3f2320980768003d3874088d))
* **docs:** add RDR-028 interactive chat architecture ([#1436](https://github.com/viamin/paid/issues/1436)) ([3d5f22c](https://github.com/viamin/paid/commit/3d5f22cd70f7a732b7570b2b1f68374ece3ce6d9))
* **multi-tenancy:** implement data isolation patterns ([#1370](https://github.com/viamin/paid/issues/1370)) ([47f2909](https://github.com/viamin/paid/commit/47f2909348ddc758e65f527d5465f77c2b06fe76))
* **temporal:** propagate tenant context into worker threads ([#1437](https://github.com/viamin/paid/issues/1437)) ([0ac5360](https://github.com/viamin/paid/commit/0ac53601e2233f01052d43698a1d4dd01ae36e45))


### Bug Fixes

* **agent-runs:** prevent circuit-breaker poisoning from StaleRunDetectorJob timeouts ([#1395](https://github.com/viamin/paid/issues/1395)) ([26c9e1c](https://github.com/viamin/paid/commit/26c9e1cb686fe59ef6516b9352bd7d9c181127f5))
* **api:** restore tenant context for container-authenticated requests ([#1445](https://github.com/viamin/paid/issues/1445)) ([ad225b6](https://github.com/viamin/paid/commit/ad225b6b8c40f34c1d6efad7d93939db8410b4b4))
* **containers:** clarify git proxy auth failures ([#1440](https://github.com/viamin/paid/issues/1440)) ([2bf627e](https://github.com/viamin/paid/commit/2bf627e372a9628a6130fd39bfc74989668ac923))
* **devcontainer:** align Postgres client tools with pinned server ([#1411](https://github.com/viamin/paid/issues/1411)) ([6f5ebaa](https://github.com/viamin/paid/commit/6f5ebaa00d26d253a985e3b356a5d55e67cd1595))
* **devcontainer:** reduce worker defaults to avoid overmind OOMs ([#1444](https://github.com/viamin/paid/issues/1444)) ([5bded16](https://github.com/viamin/paid/commit/5bded16b26c113cb251ebcc029ee254e42f2d5dc))
* **devcontainer:** run GoodJob in-process and restore activity slots ([#1446](https://github.com/viamin/paid/issues/1446)) ([8944d20](https://github.com/viamin/paid/commit/8944d2020dc73677939aa4cd8333d26768320526))
* **quality:** StaleRunDetectorJob silently skips runs when Temporal cancellation fails ([#1408](https://github.com/viamin/paid/issues/1408)) ([5077b09](https://github.com/viamin/paid/commit/5077b0988479b3479630015d96b0f2f67b171d8d))
* **scanner:** queue paid_agent review run when findings are unaddressed ([#1404](https://github.com/viamin/paid/issues/1404)) ([7750e36](https://github.com/viamin/paid/commit/7750e36a497b15e31ceabed8cea960b52b75617c))
* **test:** truncate seed data before migration spec runs ([#1442](https://github.com/viamin/paid/issues/1442)) ([72261f2](https://github.com/viamin/paid/commit/72261f27c467c35362bb6a3aaab5c464ff7d53dd))

## [0.29.0](https://github.com/viamin/paid/compare/v0.28.1...v0.29.0) (2026-04-23)


### Features

* **agent-runs:** Add label management and re-evaluation loop for enhance_issue (389-C) ([#1357](https://github.com/viamin/paid/issues/1357)) ([0850838](https://github.com/viamin/paid/commit/085083841d230934dfe2f3786ee8c34bc0491ead))
* **agent-runs:** Build EnhanceIssueActivity with knowledge base integration (389-B) ([#1342](https://github.com/viamin/paid/issues/1342)) ([795de58](https://github.com/viamin/paid/commit/795de585347757e47a4f28948ee81913c2ad2b0f))
* **agent-runs:** include pre-processed CI failure context in agent prompts ([#1393](https://github.com/viamin/paid/issues/1393)) ([9cd4dc0](https://github.com/viamin/paid/commit/9cd4dc02e1f0f7305f364845af48adda00345c53))
* **agent-runs:** move cancel cleanup to background job for faster UI response ([#1351](https://github.com/viamin/paid/issues/1351)) ([daa519a](https://github.com/viamin/paid/commit/daa519af7ccb11321dcb3203920d41ef14e3ab89))
* **deps:** add Dependabot auto-merge with bot-authored PR scanning ([#1291](https://github.com/viamin/paid/issues/1291)) ([aa2ff91](https://github.com/viamin/paid/commit/aa2ff91351b810d6b05035781d1d5b2d2cd45ed7))
* **knowledge:** add container-authenticated knowledge search endpoint for agent tool access ([#1364](https://github.com/viamin/paid/issues/1364)) ([83ab28a](https://github.com/viamin/paid/commit/83ab28a4e3f975c23d5fb19ba3beabe6bfa81b83))
* **knowledge:** inject context into enhance issue prompt ([#1340](https://github.com/viamin/paid/issues/1340)) ([6c83e1c](https://github.com/viamin/paid/commit/6c83e1c6f05aead08b96f5483c2581b3024fc448))
* **multi-tenancy:** design billing aggregation system ([#1216](https://github.com/viamin/paid/issues/1216)) ([1727d81](https://github.com/viamin/paid/commit/1727d81ad982cbf639f2d89fd77e1d48722b886f))
* **multi-tenancy:** implement per-tenant configuration ([#1369](https://github.com/viamin/paid/issues/1369)) ([bfe190d](https://github.com/viamin/paid/commit/bfe190d771d299bf13e53f678d579ea712bb8e6b))
* **performance:** database query optimization ([#1368](https://github.com/viamin/paid/issues/1368)) ([47597db](https://github.com/viamin/paid/commit/47597dbf95d9278ad712931635fd1c36b0343ebe))
* **performance:** establish performance benchmarking suite ([#1367](https://github.com/viamin/paid/issues/1367)) ([8d3888c](https://github.com/viamin/paid/commit/8d3888c3964a0a79b6bbf2cf86399b3370960c94))
* **performance:** implement container pool warming ([#1358](https://github.com/viamin/paid/issues/1358)) ([719a9f8](https://github.com/viamin/paid/commit/719a9f8d3ca8757949595c87b85b836e7ce5e13e))
* **quality:** add enhance issue metrics ([#1355](https://github.com/viamin/paid/issues/1355)) ([15aee2f](https://github.com/viamin/paid/commit/15aee2f3f4b2906210b182d485a3f66db7f14d1a))
* **quality:** add grace period after manual quality-pause resume ([#1397](https://github.com/viamin/paid/issues/1397)) ([15a561c](https://github.com/viamin/paid/commit/15a561cd90f0ea83ab6cac832d0b9b456f76292f))
* **quality:** add UI to view and unpause quality-paused projects ([#1392](https://github.com/viamin/paid/issues/1392)) ([2b1446f](https://github.com/viamin/paid/commit/2b1446f0b0160c9359dfac682ce45e10fbc68b6d))
* **quality:** define configurable quality thresholds per project ([#1354](https://github.com/viamin/paid/issues/1354)) ([94ceee5](https://github.com/viamin/paid/commit/94ceee59401b4dd9fbcbba1e0b512bb07c35bfef))
* **quality:** implement quality gate checks in agent workflows ([#1356](https://github.com/viamin/paid/issues/1356)) ([24badfa](https://github.com/viamin/paid/commit/24badfa7f3b8a17f1b4281e89a2f722ed7980c8c))
* **scheduler:** within-user fair queueing across projects ([#1343](https://github.com/viamin/paid/issues/1343)) ([70ee6cc](https://github.com/viamin/paid/commit/70ee6cc52e9b12dd3ae141f02657cca0f84972aa))


### Bug Fixes

* 724: feat(scaling): export worker metrics for scaling decisions ([#1213](https://github.com/viamin/paid/issues/1213)) ([28bfc72](https://github.com/viamin/paid/commit/28bfc7299d77400003694ec5e21ce495b1ea98e1))
* 794: refactor(agent-image): delegate Cursor agent CLI installation to agent-harness ([#1250](https://github.com/viamin/paid/issues/1250)) ([6e24b57](https://github.com/viamin/paid/commit/6e24b577f3ef5ef31159b9898a8ff4b5a4d9d4d5))
* **agent-runs:** handle unsupported auth refresh flows ([#1331](https://github.com/viamin/paid/issues/1331)) ([b78b408](https://github.com/viamin/paid/commit/b78b408185d6b97d9aaa1f1eaca53022d36d6506))
* **agent-runs:** harden provider execution fallback ([#1320](https://github.com/viamin/paid/issues/1320)) ([bfa5f90](https://github.com/viamin/paid/commit/bfa5f90729ae8b2df35d4b7a84667fa261ccdf52))
* **agent-runs:** parse JSONL output from Codex and other providers ([#1332](https://github.com/viamin/paid/issues/1332)) ([0f27e76](https://github.com/viamin/paid/commit/0f27e7654c42a03caba95aea3b78a76b24eb7f5a))
* **auto-release:** handle package names in release titles and empty check runs ([#1323](https://github.com/viamin/paid/issues/1323)) ([ddb5910](https://github.com/viamin/paid/commit/ddb5910a42c812bc738158a5ab500062269fd16a))
* **autopick:** use automation label for handed-off PRs ([#1322](https://github.com/viamin/paid/issues/1322)) ([091bdf3](https://github.com/viamin/paid/commit/091bdf3308b7f8bb369850142e52efe36076f3be))
* **containers:** align network isolation claims across provider auth modes ([#1347](https://github.com/viamin/paid/issues/1347)) ([fa2dae0](https://github.com/viamin/paid/commit/fa2dae0fa21e4fddf78205e4839335c0c968b30d))
* **css:** limit Tailwind watch source scope ([#1333](https://github.com/viamin/paid/issues/1333)) ([b5cdac8](https://github.com/viamin/paid/commit/b5cdac88dcdba4c1743f7fd5d3414df6e6d3e6f8))
* **dependabot:** rescan bot-authored ready PRs when CI status changes ([#1385](https://github.com/viamin/paid/issues/1385)) ([afac63e](https://github.com/viamin/paid/commit/afac63e87112e9ae602b882ed7d4f88ca2aa4548))
* **deps:** use released agent-harness codex parser ([#1352](https://github.com/viamin/paid/issues/1352)) ([9c6bf1e](https://github.com/viamin/paid/commit/9c6bf1e4d58b9979b5ff77b4f9b51fed7482233f))
* **devcontainer:** repair llm tool setup and codex config mounts ([#1316](https://github.com/viamin/paid/issues/1316)) ([1ab860b](https://github.com/viamin/paid/commit/1ab860b003825a646a8e2c4bd55720b0e54aa13e))
* **github-sync:** back off non-truncated incremental watermark by 1 second ([#1307](https://github.com/viamin/paid/issues/1307)) ([2f99049](https://github.com/viamin/paid/commit/2f99049e4c98b83ad0278a4aad2e1d80bd35b98f)), closes [#1257](https://github.com/viamin/paid/issues/1257)
* **github-sync:** reconcile open pull requests ([#1339](https://github.com/viamin/paid/issues/1339)) ([1ff868d](https://github.com/viamin/paid/commit/1ff868da48646ed4616c1af1534d0f25c8b8f435))
* **infra:** schema.rb drift from shared database across agent containers ([#1311](https://github.com/viamin/paid/issues/1311)) ([b82f501](https://github.com/viamin/paid/commit/b82f501819c7b81bba1802f55cdec97c65470a9a))
* **maintenance:** recover stale paused runs ([#1326](https://github.com/viamin/paid/issues/1326)) ([d8c1743](https://github.com/viamin/paid/commit/d8c17430f7ceb8a126738e508848a46a460ed412))
* **notifications:** navigate dropdown links at top frame ([#1341](https://github.com/viamin/paid/issues/1341)) ([8fbf4fe](https://github.com/viamin/paid/commit/8fbf4fe0acfc25994e03cb69a7b63364ae2bf3ca))
* **perf:** add GoodJob cleanup and reduce metrics collection interval ([#1329](https://github.com/viamin/paid/issues/1329)) ([be283ef](https://github.com/viamin/paid/commit/be283effca287a07578220142672eb71dffa153a))
* **prompts:** prepare bundled gems before review validation ([#1328](https://github.com/viamin/paid/issues/1328)) ([90d3bf0](https://github.com/viamin/paid/commit/90d3bf0b33b99a20d4a6f8a206f9c38b898a4e37))
* **providers:** make test agent checks handle provider output ([#1317](https://github.com/viamin/paid/issues/1317)) ([e10288b](https://github.com/viamin/paid/commit/e10288b10c334c5f40ee229f4095f86e33798d08))
* **quality:** apply operational failure exclusion consistently across all scoring paths ([7b86518](https://github.com/viamin/paid/commit/7b8651870da7be40388b2d7bb91af342e2eb5d03)), closes [#1376](https://github.com/viamin/paid/issues/1376)
* **quality:** broaden operational failure classification for quality scoring ([#1387](https://github.com/viamin/paid/issues/1387)) ([11d0dd0](https://github.com/viamin/paid/commit/11d0dd0265045a1b449e4582600bb23b69bd66e9))
* **quality:** exclude non-prompt failures from quality pause scoring ([#1377](https://github.com/viamin/paid/issues/1377)) ([7eade54](https://github.com/viamin/paid/commit/7eade548db9e02365e94d69fc37766b888bfe64e)), closes [#1376](https://github.com/viamin/paid/issues/1376)
* **quality:** priority bypass ignores PR labels in CheckQualityGateActivity ([#1366](https://github.com/viamin/paid/issues/1366)) ([12e6767](https://github.com/viamin/paid/commit/12e6767dba2508f1d3f0661160673ad6093adf4e))
* **quality:** use past 10 eligible agent runs for quality pause rolling average ([#1396](https://github.com/viamin/paid/issues/1396)) ([93c39c8](https://github.com/viamin/paid/commit/93c39c8315b0b9465b8e72621ec7e93047b831d4))
* **review:** track reviews without html_url ([#1363](https://github.com/viamin/paid/issues/1363)) ([c69b16d](https://github.com/viamin/paid/commit/c69b16d0ec23e69293c45fc1629ec7239625c5e7))
* **scanner:** apply hard gate to review_bot_review_pending matching paid_agent behavior ([#1336](https://github.com/viamin/paid/issues/1336)) ([#1337](https://github.com/viamin/paid/issues/1337)) ([7e7c15f](https://github.com/viamin/paid/commit/7e7c15fdc992a08ca12a9aa45c48370e0dd9ff38))
* **scanner:** unify review_bot_review_pending and paid_agent_review_pending into a single hard-gated code path ([#1338](https://github.com/viamin/paid/issues/1338)) ([1505553](https://github.com/viamin/paid/commit/1505553bd4c0c0ee0b843b0c351ed103d6f1740c))
* **secrets:** remove direct provider credential injection from agent runs ([#1349](https://github.com/viamin/paid/issues/1349)) ([c69379b](https://github.com/viamin/paid/commit/c69379b5d35e1b3c5e93463a52a2cf35b9d515d9))
* **security:** remove severity threshold and add priority mapping for code scanning alerts ([#1279](https://github.com/viamin/paid/issues/1279)) ([b43595c](https://github.com/viamin/paid/commit/b43595c0bfc1f404e67d298f6b193af69f470b2d))
* share Codex auth via writable bind mount ([#1391](https://github.com/viamin/paid/issues/1391)) ([99d6b01](https://github.com/viamin/paid/commit/99d6b013e7f26e73ac397bfce7097479de4b2423))
* **ui:** fix dark mode by unlayering CSS overrides ([#1359](https://github.com/viamin/paid/issues/1359)) ([fec8d7f](https://github.com/viamin/paid/commit/fec8d7f06757651c47fefc4fd4e80a43dfee1ab4))
* **ui:** improve dark mode coverage ([#1350](https://github.com/viamin/paid/issues/1350)) ([7d2c4e6](https://github.com/viamin/paid/commit/7d2c4e6749c22937fb629eda19efe97ee3e72ec0))

## [0.28.1](https://github.com/viamin/paid/compare/v0.28.0...v0.28.1) (2026-04-19)


### Bug Fixes

* 709: feat(evolution): define fitness function for prompt quality ([#1199](https://github.com/viamin/paid/issues/1199)) ([56c4ae8](https://github.com/viamin/paid/commit/56c4ae808e23eec521d2dd095d2db01600084570))
* 716: feat(quality): implement quality recovery workflows ([#1206](https://github.com/viamin/paid/issues/1206)) ([f8f30bc](https://github.com/viamin/paid/commit/f8f30bce1c80341f52edce0b5051ce1da74e70b1))
* **agent-runs:** push rebase-only PR followups ([#1306](https://github.com/viamin/paid/issues/1306)) ([4f37a8c](https://github.com/viamin/paid/commit/4f37a8cd4b870e0f449240bc48887a31e663c390))
* **agent-runs:** strip Claude CLI JSON envelope from agent summary ([#1298](https://github.com/viamin/paid/issues/1298)) ([8c87cd8](https://github.com/viamin/paid/commit/8c87cd8628679a89d90954ccea836d623f0d611c))

## [0.28.0](https://github.com/viamin/paid/compare/v0.27.0...v0.28.0) (2026-04-19)


### Features

* **agent-runs:** add idle timeout for create_pr agent runs ([#1225](https://github.com/viamin/paid/issues/1225)) ([57ee92e](https://github.com/viamin/paid/commit/57ee92e21ccdfe9e0657c6c12181c4ca98b58ea6)), closes [#849](https://github.com/viamin/paid/issues/849)
* **dev:** add post-checkout hook to auto-sync migrations on branch switch ([#1292](https://github.com/viamin/paid/issues/1292)) ([4581f5f](https://github.com/viamin/paid/commit/4581f5f24f3b1a320bebbe404022962edf694670))


### Bug Fixes

* 1119: Extract auto-review into strategy modules ([#1186](https://github.com/viamin/paid/issues/1186)) ([b1762c4](https://github.com/viamin/paid/commit/b1762c43178f504cc174957d0fda6bfed468e1f8))
* 1122: Extract auto-pick into strategy modules ([#1188](https://github.com/viamin/paid/issues/1188)) ([5544f9c](https://github.com/viamin/paid/commit/5544f9cbe356d8c134f77bfee3c459496d16a72a))
* 660: Support custom issue trackers (configurable at project/user/account level) ([#1243](https://github.com/viamin/paid/issues/1243)) ([703a754](https://github.com/viamin/paid/commit/703a754e53a8ff71745d5925adc57b8c2b38beaa))
* 665: Support PR templates (configurable at project/user/account level) ([#1229](https://github.com/viamin/paid/issues/1229)) ([a42ad2d](https://github.com/viamin/paid/commit/a42ad2d855bd36146f509c6c1b4c9f9b759f65aa))
* 697: feat(orchestration): coordination between related agents ([#1228](https://github.com/viamin/paid/issues/1228)) ([7474062](https://github.com/viamin/paid/commit/747406214880c3608ba8a416c3fb4f66f5f42dac))
* 710: feat(evolution): implement evolutionary selection of prompts ([#1200](https://github.com/viamin/paid/issues/1200)) ([001b748](https://github.com/viamin/paid/commit/001b748397974f6cb0201f3f288e93d1bbc7e800))
* 717: feat(quality): enhance quality trend analysis with gate integration ([#1207](https://github.com/viamin/paid/issues/1207)) ([5472d29](https://github.com/viamin/paid/commit/5472d29975391b9e53588cf7419d04eecdfb81be))
* 726: feat(scaling): design scaling algorithm for worker pools ([#1211](https://github.com/viamin/paid/issues/1211)) ([f3810cc](https://github.com/viamin/paid/commit/f3810cc26d496b9519a8448362c72b0ad229a0ca))
* 729: feat(multi-tenancy): design tenant model and isolation strategy ([#1215](https://github.com/viamin/paid/issues/1215)) ([8824a95](https://github.com/viamin/paid/commit/8824a952b98a3098e65071904fd12f3829057230))
* 778: Replace "primary provider" with "automated provider" and add multi-provider modes ([#1203](https://github.com/viamin/paid/issues/1203)) ([fd1e08b](https://github.com/viamin/paid/commit/fd1e08bb02992475c60a06a5289415b3e3e0ebdf))
* 779: feat(reviews): allow fallback code review strategies with token limits ([#1195](https://github.com/viamin/paid/issues/1195)) ([e5e1aaf](https://github.com/viamin/paid/commit/e5e1aaf8a8190d8a5466914817e49f951ff881b3))
* 789: refactor(agent-image): delegate Codex CLI installation to agent-harness ([#1248](https://github.com/viamin/paid/issues/1248)) ([e88ec13](https://github.com/viamin/paid/commit/e88ec13bc236f18954e57f47196773722c209a40))
* 790: refactor(agent-image): delegate Gemini CLI installation to agent-harness ([#1247](https://github.com/viamin/paid/issues/1247)) ([722e9f8](https://github.com/viamin/paid/commit/722e9f83d920937ab1b57b88e7dfbd6d3d76240a))
* **agent-runs:** remove stale run detection from startup cleanup ([#1277](https://github.com/viamin/paid/issues/1277)) ([850f1ba](https://github.com/viamin/paid/commit/850f1ba0a93a05cb980b099fb1edcc4490fa5c5f))
* **release:** preserve conventional PR titles ([#1294](https://github.com/viamin/paid/issues/1294)) ([10ca996](https://github.com/viamin/paid/commit/10ca99620a4953f520b9e18139ebf41f7c91be43))

## [0.27.0](https://github.com/viamin/paid/compare/v0.26.0...v0.27.0) (2026-04-18)


### Features

* **agent-execution:** abort container early on provider quota errors that hang ([#1251](https://github.com/viamin/paid/issues/1251)) ([af9fbc7](https://github.com/viamin/paid/commit/af9fbc7fbf795d4da7d9f470cc9fb30a58775205)), closes [#827](https://github.com/viamin/paid/issues/827)
* **dashboard:** include merged pull requests in the recent activity stream ([#1264](https://github.com/viamin/paid/issues/1264)) ([3cbf708](https://github.com/viamin/paid/commit/3cbf708179b19994fd912a88b392c0311a339a87))
* **evolution:** implement PromptEvolutionWorkflow ([#706](https://github.com/viamin/paid/issues/706)) ([#1245](https://github.com/viamin/paid/issues/1245)) ([df041d6](https://github.com/viamin/paid/commit/df041d6d6c8494c024737533e8af54f228098503))


### Bug Fixes

* 714: feat(quality): automatic pause on quality threshold breach ([#1205](https://github.com/viamin/paid/issues/1205)) ([ea94fcc](https://github.com/viamin/paid/commit/ea94fcc30ab0da7a411c4ac87ddf90c9ff139c28))
* 719: feat(performance): workflow batching optimizations ([#1208](https://github.com/viamin/paid/issues/1208)) ([ea7c306](https://github.com/viamin/paid/commit/ea7c3067e94cc598e4848a9b899785439a1a50c8))
* 721: feat(performance): add caching layer for GitHub data ([#1209](https://github.com/viamin/paid/issues/1209)) ([12c2cb7](https://github.com/viamin/paid/commit/12c2cb7439206915d872fdbf417b13e642a841c9))
* 727: feat(scaling): add integration points for container orchestrators ([#1214](https://github.com/viamin/paid/issues/1214)) ([3bb3a0a](https://github.com/viamin/paid/commit/3bb3a0adc5095b78e915618dd6ee9c9efbe1d9f4))
* 802: "Back to ..." links should return to the previous page, not a hardcoded destination ([#1232](https://github.com/viamin/paid/issues/1232)) ([4026eb1](https://github.com/viamin/paid/commit/4026eb1524392fc055ab8ef58a52f1da4cebf10b))
* 854: feat(agent-harness): add heartbeat/progress support to agent-harness gem ([#1233](https://github.com/viamin/paid/issues/1233)) ([3f49a8f](https://github.com/viamin/paid/commit/3f49a8f0adec65908c0cbafadbfa3154f511ee48))

## [0.26.0](https://github.com/viamin/paid/compare/v0.25.0...v0.26.0) (2026-04-18)


### Features

* **quality:** alert users when quality gates trigger ([#715](https://github.com/viamin/paid/issues/715)) ([#1204](https://github.com/viamin/paid/issues/1204)) ([d5e514c](https://github.com/viamin/paid/commit/d5e514c388e995ce9f3129c12465d96d51c7f896))


### Bug Fixes

* 725: feat(scaling): implement queue depth monitoring and alerting ([#1210](https://github.com/viamin/paid/issues/1210)) ([e74e52c](https://github.com/viamin/paid/commit/e74e52ca05302e2c8c734211bbaaea235545f639))
* 799: feat(agent-runs): support cross-repo upstream/downstream issue pairs in create-issue mode ([#1218](https://github.com/viamin/paid/issues/1218)) ([cb14afa](https://github.com/viamin/paid/commit/cb14afa77f447e3d19753d9397ffef210bc06c00))
* 851: feat(providers): configure Claude Code PostToolUse heartbeat hook ([#1231](https://github.com/viamin/paid/issues/1231)) ([dc6b8ac](https://github.com/viamin/paid/commit/dc6b8acf52c5862efd09b59fbbcc6c409a839505))
* **devcontainer:** avoid kilocode permission save-merge corruption ([#1259](https://github.com/viamin/paid/issues/1259)) ([4212e03](https://github.com/viamin/paid/commit/4212e0386b5ea224584a7c96ad3e03494b265f2f))
* **scheduler:** cap auto-pick seeding at owner concurrency budget ([#1260](https://github.com/viamin/paid/issues/1260)) ([ee8bda8](https://github.com/viamin/paid/commit/ee8bda8ed7d1f55ef955eb177b0a28728276238e))

## [0.25.0](https://github.com/viamin/paid/compare/v0.24.0...v0.25.0) (2026-04-17)


### Features

* **agent-runs:** display provider information and fallback status on agent run page ([#1234](https://github.com/viamin/paid/issues/1234)) ([4f886e2](https://github.com/viamin/paid/commit/4f886e261e59a7f875d7cb3fb302ec26191df476)), closes [#803](https://github.com/viamin/paid/issues/803)
* **auto-pick:** prioritize issues by label (P1 &gt; P2 &gt; P3 &gt; unlabeled) ([#1179](https://github.com/viamin/paid/issues/1179)) ([0ebfee8](https://github.com/viamin/paid/commit/0ebfee8433d06cddee532d54577340b39df5b301)), closes [#1176](https://github.com/viamin/paid/issues/1176)
* **automation:** define provider capability interfaces ([#1116](https://github.com/viamin/paid/issues/1116)) ([#1173](https://github.com/viamin/paid/issues/1173)) ([c504ee8](https://github.com/viamin/paid/commit/c504ee8989cad4101b972a25928d82f264d9822b))
* **automation:** normalize review/automation settings into config value objects ([#1185](https://github.com/viamin/paid/issues/1185)) ([4b96bcc](https://github.com/viamin/paid/commit/4b96bcc0c9b48d86555d89e800587ebfea368498))
* **containers:** accept heartbeat file for watchdog liveness ([#850](https://github.com/viamin/paid/issues/850)) ([#1198](https://github.com/viamin/paid/issues/1198)) ([fd53233](https://github.com/viamin/paid/commit/fd5323317993f73599e96a7356204b5032b8979a))
* **models:** add max_tier project preference and tier-bypass regression tests ([#1226](https://github.com/viamin/paid/issues/1226)) ([824567a](https://github.com/viamin/paid/commit/824567a2bfcc4bb9de2fa42514266be2104c7b49)), closes [#878](https://github.com/viamin/paid/issues/878)
* **projects:** show emoji-only status in issues table with header tooltip legend ([#1223](https://github.com/viamin/paid/issues/1223)) ([5f90968](https://github.com/viamin/paid/commit/5f90968c7fad9d28e08e02a4d58568b5db53c236)), closes [#841](https://github.com/viamin/paid/issues/841)
* **providers:** configure Codex notify heartbeat hook ([#852](https://github.com/viamin/paid/issues/852)) ([#1230](https://github.com/viamin/paid/issues/1230)) ([c2d3070](https://github.com/viamin/paid/commit/c2d307021acf57fff031cc0dc5b85fc733e130b7))
* **review-runs:** prepend Code Review header to posted review comments ([#1220](https://github.com/viamin/paid/issues/1220)) ([4d04b91](https://github.com/viamin/paid/commit/4d04b914f5f9d550981d13513a0d164ccc4bf742)), closes [#840](https://github.com/viamin/paid/issues/840)
* **rollout:** enable explicit_pr_automation_decisions for viamin/paid ([#1193](https://github.com/viamin/paid/issues/1193)) ([68dc3d8](https://github.com/viamin/paid/commit/68dc3d8763e8d87af507e0140ec240af1b198b24))


### Bug Fixes

* 1118: Add GitHub automation adapters ([#1183](https://github.com/viamin/paid/issues/1183)) ([9298996](https://github.com/viamin/paid/commit/92989966d903b447eb67634cc36591cc94b51776))
* 1163: Move co-authored-by trailer from project setting to provider setting ([#1178](https://github.com/viamin/paid/issues/1178)) ([28ca0af](https://github.com/viamin/paid/commit/28ca0af8e2341f2996e088ddda6d7cdb48811bde))
* 1180: Support multi-step PRs for multi-deployment migrations ([#1191](https://github.com/viamin/paid/issues/1191)) ([8186a5f](https://github.com/viamin/paid/commit/8186a5fdd6c885c6bcadb5dcd39cd9c9d3e70af7))
* 1181: Disable issues with open paid-generated PRs from quick run in project issues table and Trigger Agent Run form ([#1184](https://github.com/viamin/paid/issues/1184)) ([df62822](https://github.com/viamin/paid/commit/df628229183d8b3c62a9ac1c3bd0b0dfb4dfcc21))
* 1235: perf(poll-workflow): batch DetectLabels into a single activity ([#1239](https://github.com/viamin/paid/issues/1239)) ([05a0985](https://github.com/viamin/paid/commit/05a09852aa2181d278c5f4e8470263521522e088))
* 1236: perf(temporal-worker): isolate poll workflows from agent execution workloads ([#1241](https://github.com/viamin/paid/issues/1241)) ([c8ce7db](https://github.com/viamin/paid/commit/c8ce7db866deaad8b6911a409704c10fa85e3264))
* 711: feat(evolution): human review gate for evolved prompts ([#1201](https://github.com/viamin/paid/issues/1201)) ([7bdfbd6](https://github.com/viamin/paid/commit/7bdfbd6e09c280c41e4f3feda85e7f8feb9f5c85))
* 728: docs(scaling): create scaling documentation and runbook ([#1212](https://github.com/viamin/paid/issues/1212)) ([6e06ac5](https://github.com/viamin/paid/commit/6e06ac5ae505aa9f65345c4b61d2dbc899c66606))
* 733: feat(multi-tenancy): design tenant onboarding flow ([#1217](https://github.com/viamin/paid/issues/1217)) ([2630ed2](https://github.com/viamin/paid/commit/2630ed297efda432ac08896865a01668bfe2b8d5))
* 784: refactor(agent-runs): move RunAgentActivity provider execution behind agent-harness ([#1244](https://github.com/viamin/paid/issues/1244)) ([7496951](https://github.com/viamin/paid/commit/7496951904d66d1012855bb38db4960d4ecb87ab))
* 788: refactor(agent-image): delegate Claude CLI installation to agent-harness ([#1249](https://github.com/viamin/paid/issues/1249)) ([114c6a4](https://github.com/viamin/paid/commit/114c6a4152712cb6a3ca5140a0d5a86f886f2b6b))
* 805: Add pause all button to agent runs page with navigation indicator ([#1194](https://github.com/viamin/paid/issues/1194)) ([f345915](https://github.com/viamin/paid/commit/f345915b1d09395566e26dfaf0000021c2a48c93))
* 829: fix(agent-runs): provider exhaustion on PR follow-up runs can leave projects effectively stalled ([#1221](https://github.com/viamin/paid/issues/1221)) ([071a3f1](https://github.com/viamin/paid/commit/071a3f179989fa24c0233a19b0f87a644bda524d))
* 842: Replace project quality summary range with score distribution histogram ([#1222](https://github.com/viamin/paid/issues/1222)) ([368fe99](https://github.com/viamin/paid/commit/368fe99cb6d1e949fcde758e2cbd93d4d95434b1))
* 863: fix(devcontainer): configure OpenCode auto-approval inside container only ([#1224](https://github.com/viamin/paid/issues/1224)) ([49f9f99](https://github.com/viamin/paid/commit/49f9f992addb4544e1a1459b47b65afd5801e732))
* 875: feat(models): map task complexity score to model tier ([#1197](https://github.com/viamin/paid/issues/1197)) ([01534a7](https://github.com/viamin/paid/commit/01534a7bda197328aff25248e978ae1bb842358f))
* 885: Add dark mode UI with user settings and system preference detection ([#1240](https://github.com/viamin/paid/issues/1240)) ([5b2a806](https://github.com/viamin/paid/commit/5b2a80692726956f63347a5d73a9f2bae303ba6c))
* **agent-runs:** prevent provider credit/quota errors from being misclassified as recommend_close ([#1192](https://github.com/viamin/paid/issues/1192)) ([#1202](https://github.com/viamin/paid/issues/1202)) ([0995240](https://github.com/viamin/paid/commit/0995240505ef98b91d248754187d207b329e3ec3))
* **auto-pick:** detect trackers by body heading, not prose ([#1187](https://github.com/viamin/paid/issues/1187)) ([5ecb794](https://github.com/viamin/paid/commit/5ecb794430db9b4b7a643550901a241daca381bd))
* **auto-pick:** resolve self-repo PR refs as local deps, not external ([#1189](https://github.com/viamin/paid/issues/1189)) ([45e8ccf](https://github.com/viamin/paid/commit/45e8ccf1df4f464c2861b5f05a638a05d07f5fa4))
* **knowledge:** create writable log/ and tmp/ in collector workspace ([#1175](https://github.com/viamin/paid/issues/1175)) ([7093508](https://github.com/viamin/paid/commit/7093508862b1f4970e9e07de21ff47eb57d58cdf))
* **poll-workflow:** heartbeat last_polled_at mid-cycle, not only at the end ([#1242](https://github.com/viamin/paid/issues/1242)) ([b7d5f21](https://github.com/viamin/paid/commit/b7d5f21f7b6c69256d13fcddda7a67485c522196)), closes [#1237](https://github.com/viamin/paid/issues/1237)
* **pr-review:** reconcile internal pr_review_phase with GitHub draft state ([#826](https://github.com/viamin/paid/issues/826)) ([#1219](https://github.com/viamin/paid/issues/1219)) ([5c8ef0b](https://github.com/viamin/paid/commit/5c8ef0b850ee2c418a2d6ba869793e3df406abb0))
* **pr-scanner:** rescan draft PRs beyond a staleness ceiling ([#1252](https://github.com/viamin/paid/issues/1252)) ([15916a7](https://github.com/viamin/paid/commit/15916a79ec695b88d4afc29d5313164ce99b417d))
* **review-runs:** avoid malformed JSON in PR review proxy requests ([#1196](https://github.com/viamin/paid/issues/1196)) ([9dfa5f0](https://github.com/viamin/paid/commit/9dfa5f05bb317be1f15d1d699c3072f468c093cc)), closes [#839](https://github.com/viamin/paid/issues/839)
* **reviews:** respect configured review methods when requesting bot reviews after push ([#1227](https://github.com/viamin/paid/issues/1227)) ([4854366](https://github.com/viamin/paid/commit/4854366b113e45013427fd793d6d752d374213bb)), closes [#860](https://github.com/viamin/paid/issues/860)
* **service-containers:** pin postgres default to 16.13 to stop schema drift ([#1256](https://github.com/viamin/paid/issues/1256)) ([2bde5e3](https://github.com/viamin/paid/commit/2bde5e3f587cbc19a1f639a5e9c7c9b233f15dc5))
* **setup:** pass Claude install contract build args to agent-image ([#1253](https://github.com/viamin/paid/issues/1253)) ([419ca07](https://github.com/viamin/paid/commit/419ca079eac934cfa4f6a2f248abdefc93a372c0))

## [0.24.0](https://github.com/viamin/paid/compare/v0.23.0...v0.24.0) (2026-04-16)


### Features

* **auto-pick:** configurable PR WIP limit ([#1168](https://github.com/viamin/paid/issues/1168)) ([9a41a0f](https://github.com/viamin/paid/commit/9a41a0f77d615119f9fb90a3e6e9afb1de8097dd))
* **automation:** introduce shared automation abstractions ([#1115](https://github.com/viamin/paid/issues/1115)) ([#1172](https://github.com/viamin/paid/issues/1172)) ([92eed64](https://github.com/viamin/paid/commit/92eed6476736d1f53b5b0e4646c961af1fdfa5d5))


### Bug Fixes

* 1165: Replace enhance issue dropdown with multi-select table (matching PR code review table) ([#1166](https://github.com/viamin/paid/issues/1166)) ([242f2f8](https://github.com/viamin/paid/commit/242f2f89a8e78ed25bc9e129ea0dac9a1a706622))
* 801: Add advanced business context intake to the knowledge base ([#1162](https://github.com/viamin/paid/issues/1162)) ([d802baa](https://github.com/viamin/paid/commit/d802baaff0f943d7113db70ffb84f23f46aaed28))
* **agent-runs:** skip git post-processing for enhance_issue and create_issue goals ([#1169](https://github.com/viamin/paid/issues/1169)) ([b65bfd3](https://github.com/viamin/paid/commit/b65bfd3fc025c8f585ef4524d3b139970a2072c8))
* **pr-description:** disable tool access for text-only LLM calls ([#1171](https://github.com/viamin/paid/issues/1171)) ([2142df0](https://github.com/viamin/paid/commit/2142df057527fda60505ff9d28b6b85a70db4414)), closes [#1146](https://github.com/viamin/paid/issues/1146)

## [0.23.0](https://github.com/viamin/paid/compare/v0.22.0...v0.23.0) (2026-04-16)


### Features

* **agent-runs:** add enhance_issue goal for issue enhancement mode ([#389](https://github.com/viamin/paid/issues/389)) ([#1153](https://github.com/viamin/paid/issues/1153)) ([d1927d2](https://github.com/viamin/paid/commit/d1927d26a914dfd440f2479c7f800396959ea7dd))
* **agent-runs:** add provider filter to agent runs index page ([#1144](https://github.com/viamin/paid/issues/1144)) ([5c25562](https://github.com/viamin/paid/commit/5c25562986976cefafe5e98cae46f94dadf46eab)), closes [#1069](https://github.com/viamin/paid/issues/1069)
* **knowledge:** add token usage tracking to knowledge dashboard ([#1046](https://github.com/viamin/paid/issues/1046)) ([#1140](https://github.com/viamin/paid/issues/1140)) ([30f6fc9](https://github.com/viamin/paid/commit/30f6fc97477e99898d029a395b3b61f8e8fd9413))
* **rdrs:** add RDR-023 automation modularization architecture ([#1161](https://github.com/viamin/paid/issues/1161)) ([0b62901](https://github.com/viamin/paid/commit/0b629012e45bdaaf022a2c958298e82d4bc0d5bf)), closes [#1114](https://github.com/viamin/paid/issues/1114)
* **token-tracking:** ingest Codex token usage data ([#1030](https://github.com/viamin/paid/issues/1030)) ([#1143](https://github.com/viamin/paid/issues/1143)) ([31b33d0](https://github.com/viamin/paid/commit/31b33d0b5aba4e10a921cc6eee052e2932314a81))


### Bug Fixes

* 1037: codex: revisit containerized subscription-auth seeding for refresh-rotating OAuth sessions ([#1100](https://github.com/viamin/paid/issues/1100)) ([61d0ff4](https://github.com/viamin/paid/commit/61d0ff4acd32c177a191a5728c167fa2d4b273d4))
* 1042: feat(knowledge): containerize decision drafting to use secrets proxy ([#1145](https://github.com/viamin/paid/issues/1145)) ([c2f0d70](https://github.com/viamin/paid/commit/c2f0d70cdfe7b53581586001dff1c0b69e30f554))
* 1050: feat(providers): implement rate-limit fallback execution ([#1108](https://github.com/viamin/paid/issues/1108)) ([a8fa62d](https://github.com/viamin/paid/commit/a8fa62df1bf8943702c8268ac97ec9c2efca017f))
* 1125: Orphan Branches Without PRs: Implement Pre-Run Branch Existence Check ([#1141](https://github.com/viamin/paid/issues/1141)) ([babcd5f](https://github.com/viamin/paid/commit/babcd5fb608719dd6a34e343fab63c21e44b5008))
* 1148: feat(release): auto-merge release-please PRs based on per-project semver policy ([#1150](https://github.com/viamin/paid/issues/1150)) ([4ebfe90](https://github.com/viamin/paid/commit/4ebfe900f46a8857ca84c18fe2e648b6c1633a97))
* 1149: feat(projects): ensure standard labels (P1/P2/P3, etc.) exist on connected GitHub repos ([#1160](https://github.com/viamin/paid/issues/1160)) ([8ad917b](https://github.com/viamin/paid/commit/8ad917b9047ee1d4706dbc8343d3162aaa7c34c5))
* **containers:** retry git clone on transient DNS/network failures ([#1159](https://github.com/viamin/paid/issues/1159)) ([04cf981](https://github.com/viamin/paid/commit/04cf9819d37037cd632ae11d6b618cc623a4f4fa)), closes [#1151](https://github.com/viamin/paid/issues/1151)
* **dev:** wait for overmind socket before exiting from --detach ([#1158](https://github.com/viamin/paid/issues/1158)) ([46cb5ff](https://github.com/viamin/paid/commit/46cb5ff1c1e125c612bd0e2ffc4f3ac754dab4c0))
* **knowledge:** increase collector container memory and tmpfs to fix routes OOM ([#1167](https://github.com/viamin/paid/issues/1167)) ([81fb987](https://github.com/viamin/paid/commit/81fb98717e9f16e7bc52fcdc4b2ece379f7afc00))
* **knowledge:** mount /tmp tmpfs with exec for collector container ([#1155](https://github.com/viamin/paid/issues/1155)) ([b205ceb](https://github.com/viamin/paid/commit/b205ceb58f10f4b57b827c22cae919525508bef8))
* **pr-scanner:** return :skipped from scan_draft_pr when CI is pending ([#1157](https://github.com/viamin/paid/issues/1157)) ([cafbbcc](https://github.com/viamin/paid/commit/cafbbcc42a221a4881b1c7cf17f01308cb02d8d1)), closes [#1156](https://github.com/viamin/paid/issues/1156)
* **scanner:** pause PR follow-up runs while paid_agent review is outstanding ([#1135](https://github.com/viamin/paid/issues/1135)) ([#1142](https://github.com/viamin/paid/issues/1142)) ([bdc5d53](https://github.com/viamin/paid/commit/bdc5d5319f4ad6e2b13470f3f42fcc49cad33736))
* **scanner:** prevent review loop when HEAD equals reviewed commit ([#1152](https://github.com/viamin/paid/issues/1152)) ([#1154](https://github.com/viamin/paid/issues/1154)) ([1bc0d1d](https://github.com/viamin/paid/commit/1bc0d1d44980d69ddd5012a4bb54e940ac67bc6e))

## [0.22.0](https://github.com/viamin/paid/compare/v0.21.0...v0.22.0) (2026-04-15)


### Features

* **dev:** add --restart-if-running flag to restart healthy Overmind sessions ([2104015](https://github.com/viamin/paid/commit/2104015cb21a4fa5270941bbdba3e1a99fe21e73))
* **dev:** add --restart-if-running flag to restart healthy Overmind sessions ([#1138](https://github.com/viamin/paid/issues/1138)) ([f363525](https://github.com/viamin/paid/commit/f363525921390f3fb53e735b8d004804a0d05821))
* **setup:** update bin/setup to use --restart-if-running when starting dev server ([f363525](https://github.com/viamin/paid/commit/f363525921390f3fb53e735b8d004804a0d05821))
* **setup:** update bin/setup to use --restart-if-running when starting dev server ([2104015](https://github.com/viamin/paid/commit/2104015cb21a4fa5270941bbdba3e1a99fe21e73))


### Bug Fixes

* 1012: feat(settings): address all bot reviews regardless of configured review method ([#1103](https://github.com/viamin/paid/issues/1103)) ([b70f5b0](https://github.com/viamin/paid/commit/b70f5b01210b2f365829e2434e0759fcf5eb4dd5))
* 1032: feat(token-tracking): ingest GitHub Copilot CLI token usage data from agent-harness ([#1104](https://github.com/viamin/paid/issues/1104)) ([97ec311](https://github.com/viamin/paid/commit/97ec311fe63d08bb9df50f78662c6bd25f5abf40))
* 1041: feat(knowledge): add provider fallback configuration for knowledge base LLM operations ([#1087](https://github.com/viamin/paid/issues/1087)) ([475da3e](https://github.com/viamin/paid/commit/475da3e9d12ddc5e5d602dcba2cabd0008129bb0))
* 1049: fix(agent-runs): transient container errors silently mark runs as no_output ([#1107](https://github.com/viamin/paid/issues/1107)) ([fed76c7](https://github.com/viamin/paid/commit/fed76c7b6d87ebf457bcdaec2463bffc32f49314))
* 1058: feat(ci): gate Claude code review workflow on project review settings via repository_dispatch ([#1111](https://github.com/viamin/paid/issues/1111)) ([811d6af](https://github.com/viamin/paid/commit/811d6afa26ab29a34a533f20f3613acd3483c845))
* 1082: refactor(automation): unify issue and PR automation behind an explicit decision layer ([#1136](https://github.com/viamin/paid/issues/1136)) ([cdb7591](https://github.com/viamin/paid/commit/cdb7591fafbf485f855b91193c9c179c60bb7ca9))
* 797: refactor(providers): move OpenCode runtime bootstrap out of Paid and into agent-harness ([#1102](https://github.com/viamin/paid/issues/1102)) ([5e17a2c](https://github.com/viamin/paid/commit/5e17a2c4db3c2589dcdeaf79a1c79b0057db2eb1))

## [0.21.0](https://github.com/viamin/paid/compare/v0.20.2...v0.21.0) (2026-04-14)


### Features

* **token-tracking:** verify aider token ingestion ([#1105](https://github.com/viamin/paid/issues/1105)) ([55e1ea1](https://github.com/viamin/paid/commit/55e1ea1c18e0c993a4260dfb7b8acdfa5be56654))


### Bug Fixes

* 1028: providers page: collapse configuration instructions by default and add instruction blocks for all supported providers ([#1101](https://github.com/viamin/paid/issues/1101)) ([fb88d8a](https://github.com/viamin/paid/commit/fb88d8a8cfde9728791c446c8b7aac5602ac46e3))
* 1031: feat(token-tracking): ingest Kilo (kilocode) token usage data from agent-harness ([#1106](https://github.com/viamin/paid/issues/1106)) ([9207328](https://github.com/viamin/paid/commit/9207328f04c11a8afe9e095e7c45043a696263c1))
* 1036: codex: classify refresh_token_reused as auth_expired instead of generic provider error ([#1090](https://github.com/viamin/paid/issues/1090)) ([6bf9c3f](https://github.com/viamin/paid/commit/6bf9c3fb682a02ddb1d9a00c33a9b08e70035354))
* 1040: feat(knowledge): extend secrets proxy to authenticate knowledge-run operations ([#1088](https://github.com/viamin/paid/issues/1088)) ([6c3226e](https://github.com/viamin/paid/commit/6c3226ea68d4906a2bea91ba50d555369ec100bd))
* 1051: fix(agent-runs): has_changes? fallback misses committed changes when base_commit_sha is nil ([#1109](https://github.com/viamin/paid/issues/1109)) ([e849f0f](https://github.com/viamin/paid/commit/e849f0f86efdbfaf0b0c099cc72488855a91df6b))
* 1056: fix(workflow): silent restart failure when WorkflowAlreadyStartedError is raised ([#1096](https://github.com/viamin/paid/issues/1096)) ([97807ea](https://github.com/viamin/paid/commit/97807eaaf455ebcb6b9805ee3a6c71446f6b6947))
* 1057: fix(workflow): health check doesn't record stale state before restart ([#1099](https://github.com/viamin/paid/issues/1099)) ([c55d020](https://github.com/viamin/paid/commit/c55d020902fa94e8082088710459fa3dc7015a1a))
* 1072: fix(scanner): backfill review_goal_retry_reset_at for existing issues ([#1092](https://github.com/viamin/paid/issues/1092)) ([fd7ec48](https://github.com/viamin/paid/commit/fd7ec48e4bacb085b863eaca3f6fad2e333b6a1c))
* 1078: Automate enqueuing of paid‑code‑review agent runs for PRs without active runs ([#1112](https://github.com/viamin/paid/issues/1112)) ([58c6594](https://github.com/viamin/paid/commit/58c65948b869aee4046f8adf806f9de2c894e413))
* 1080: fix(automation): initial sync can start create_pr runs for existing PRs with only review-pending signals ([#1084](https://github.com/viamin/paid/issues/1084)) ([5c488e2](https://github.com/viamin/paid/commit/5c488e2528e0ed74cd23776929b2fe5d775773e5))
* 1085: feat(infrastructure): add Flipper-based feature flags for staged automation rollouts ([#1091](https://github.com/viamin/paid/issues/1091)) ([5cd374d](https://github.com/viamin/paid/commit/5cd374d0bc0a9d7800a08d961a6d0e42f280ff7c))
* **agent-runs:** fail invalid create-issue fallback runs ([#1068](https://github.com/viamin/paid/issues/1068)) ([33ff648](https://github.com/viamin/paid/commit/33ff6485af623cff73fed13a58a50a336b923cbb))
* **agent-runs:** resolve addressed review threads on no-change PR runs ([#1077](https://github.com/viamin/paid/issues/1077)) ([f1a6140](https://github.com/viamin/paid/commit/f1a6140999abfedb506d1fdf5e7d05b0fc846bba))
* **agent-runs:** sync created pull requests into local cache ([#1132](https://github.com/viamin/paid/issues/1132)) ([1ed0a4a](https://github.com/viamin/paid/commit/1ed0a4af9d919a7c90dd7449e53fdb90490f2bf4))
* **pr-review:** requeue paid-agent reviews and raise default review rounds ([#1133](https://github.com/viamin/paid/issues/1133)) ([03e2022](https://github.com/viamin/paid/commit/03e202209ba6738e395e81cac88c9337b27e5038))
* **projects:** colorize synced issue priority labels ([#1110](https://github.com/viamin/paid/issues/1110)) ([374de7e](https://github.com/viamin/paid/commit/374de7e92def7f6e94a3f29eb37cd49b40597572))
* **prompts:** exclude paid-generated PR comments from followup prompts ([#1134](https://github.com/viamin/paid/issues/1134)) ([bbfd852](https://github.com/viamin/paid/commit/bbfd852d695c505c08e1194b7ecad20dc2cf1f95))
* **prompts:** limit PR conversation context ([#1097](https://github.com/viamin/paid/issues/1097)) ([d5cfb61](https://github.com/viamin/paid/commit/d5cfb61f7f381c744e5a149ce38e3994f8719d19))
* **providers:** wrap fallback order around active primary ([#1093](https://github.com/viamin/paid/issues/1093)) ([ffceaea](https://github.com/viamin/paid/commit/ffceaea32a7688dd204909d13893d14365432cfe))
* **workflow:** allow restarting stale monitors ([#1094](https://github.com/viamin/paid/issues/1094)) ([8cff03d](https://github.com/viamin/paid/commit/8cff03df258459d9b38388b64154b339f1022c3a))
* **workflow:** keep restart button in status broadcasts ([#1095](https://github.com/viamin/paid/issues/1095)) ([0dc678d](https://github.com/viamin/paid/commit/0dc678daa40c4d53e3a9e4462c2919f91ee9e0ee))

## [0.20.2](https://github.com/viamin/paid/compare/v0.20.1...v0.20.2) (2026-04-13)


### Bug Fixes

* **auto-merge:** handle zero-check repos correctly ([#1075](https://github.com/viamin/paid/issues/1075)) ([d95e932](https://github.com/viamin/paid/commit/d95e932d49e81db7d0a7c8ebd22e271cf351851c))
* **knowledge:** restore routes collector networking ([#1073](https://github.com/viamin/paid/issues/1073)) ([33a4d76](https://github.com/viamin/paid/commit/33a4d768fd0114fc23f8e2a4f1690fc090dba6c3))
* **scanner:** stop review-goal retries after cancelled runs ([#1076](https://github.com/viamin/paid/issues/1076)) ([ae9334a](https://github.com/viamin/paid/commit/ae9334a9cb00719358252206655662a98e90c078))

## [0.20.1](https://github.com/viamin/paid/compare/v0.20.0...v0.20.1) (2026-04-13)


### Bug Fixes

* 1002: fix(scanner): no recovery path when review-goal agent run fails ([#1019](https://github.com/viamin/paid/issues/1019)) ([e7873c0](https://github.com/viamin/paid/commit/e7873c062c6f7c02d4c419295c9a8af8c17056f9))

## [0.20.0](https://github.com/viamin/paid/compare/v0.19.0...v0.20.0) (2026-04-12)


### Features

* **agent-runs:** add "no_output" status for unproductive create_pr runs ([5221217](https://github.com/viamin/paid/commit/522121783fe003ada2e8f57db3af8cf9b11cd0a2))
* **agent-runs:** add defense-in-depth mitigations for PR description scope contamination ([#905](https://github.com/viamin/paid/issues/905)) ([009e546](https://github.com/viamin/paid/commit/009e5468f2a8364a420938e026ed48671b2ea528))
* **agent-runs:** add diff-overlap check for summary scope validation ([b3aabfe](https://github.com/viamin/paid/commit/b3aabfeb8337842d3a2ae5e47f68a1fa836d60a7))
* **agent-runs:** add no_output status for unproductive create_pr runs ([d5372c2](https://github.com/viamin/paid/commit/d5372c2dc5f8cfb45763aff560cc6faac9c2331f))
* **agent-runs:** add priority select input to trigger agent run form ([df0771c](https://github.com/viamin/paid/commit/df0771c256caf2f99288669fa64c2c7b3b61695a)), closes [#958](https://github.com/viamin/paid/issues/958)
* **agent-runs:** optimize queue priority SQL with LATERAL join and P1/P2/P3 labels ([#933](https://github.com/viamin/paid/issues/933)) ([8b1bbe0](https://github.com/viamin/paid/commit/8b1bbe01b45b0c5eee9a6b5b20308e6f488658a6))
* **agent-runs:** replace PR dropdown with multi-select table for review goal ([bbe95ab](https://github.com/viamin/paid/commit/bbe95abe7b504ebba1570e35293198b8352a0f18)), closes [#957](https://github.com/viamin/paid/issues/957)
* **dashboard:** rename Agent column to Goal in active runs table ([bd22192](https://github.com/viamin/paid/commit/bd22192382f522d8eee9999b91bba96423c0e10d)), closes [#987](https://github.com/viamin/paid/issues/987)
* **notifications:** add notification center with bell icon, badges, and link-through ([#912](https://github.com/viamin/paid/issues/912)) ([5857a71](https://github.com/viamin/paid/commit/5857a710c37284ba04bf461b05dd754cb32393bb))
* **projects:** add manual stale run cleanup ([59e27a2](https://github.com/viamin/paid/commit/59e27a2eb37ffc47968fb1b8580aeb6afdeeebbf))
* **projects:** add review type indicator badges to projects index ([2ae6ae1](https://github.com/viamin/paid/commit/2ae6ae1c025ef556cee213812d69754ca085eb26)), closes [#930](https://github.com/viamin/paid/issues/930)
* **projects:** add UI fields for configuring priority label names ([#923](https://github.com/viamin/paid/issues/923)) ([dec53a4](https://github.com/viamin/paid/commit/dec53a4241479a5ca841965ee81ba2d020b30c8e))
* **projects:** change default execution timeout from 1800s to 3600s ([5702195](https://github.com/viamin/paid/commit/570219595f35bb19f27c8d3e4d4ff4bc4d3bf775))
* **projects:** change default execution timeout from 1800s to 3600s ([#855](https://github.com/viamin/paid/issues/855)) ([fd56c9e](https://github.com/viamin/paid/commit/fd56c9e82f6cc1b4b57836c0c3fadbdf60576faa))
* **projects:** increase default issue/PR count to 50 with user-configurable setting ([e8c2503](https://github.com/viamin/paid/commit/e8c25032ad6689d3f017b354e7dc200d58bce5c6)), closes [#962](https://github.com/viamin/paid/issues/962)
* **projects:** show recently merged pull requests ([#774](https://github.com/viamin/paid/issues/774)) ([3df8ac4](https://github.com/viamin/paid/commit/3df8ac460ad8903d4a0807931959445a5d899463))
* **prompts:** migrate all agent prompts into the prompts table ([5a74d9c](https://github.com/viamin/paid/commit/5a74d9c2f4e6a800b1edf97acc2c945169892544))
* **prompts:** migrate all agent prompts into the prompts table ([31692f0](https://github.com/viamin/paid/commit/31692f01535b59bd26e5f29a50d312cb3abcfc60))
* **prompts:** migrate goal-augmentation prompts and ban praise-only PR review comments ([2829c3d](https://github.com/viamin/paid/commit/2829c3dbe131856e01cab54a320346f4f4d395d4))
* **providers:** add z.ai to DIRECT_OUTBOUND_API_PROVIDERS ([7b360d8](https://github.com/viamin/paid/commit/7b360d88ebb9e0721459baca49d3125cabcf876f))
* **providers:** add z.ai to DIRECT_OUTBOUND_API_PROVIDERS ([8ca5cf2](https://github.com/viamin/paid/commit/8ca5cf2ce272b0aa96a2bcb478b03af55a6ec131)), closes [#845](https://github.com/viamin/paid/issues/845)
* **providers:** multi-provider direct outbound for OpenCode and KiloCode ([#769](https://github.com/viamin/paid/issues/769)) ([45fc24d](https://github.com/viamin/paid/commit/45fc24daf323058d09248ff9b3b79b125e728a62))
* **providers:** register z.ai in API_SERVICE_TYPES only ([0e9c901](https://github.com/viamin/paid/commit/0e9c90105f7ea7e1248902918d89e473339665ed))
* **providers:** register z.ai in API_SERVICE_TYPES only ([86a9e28](https://github.com/viamin/paid/commit/86a9e28383ddcae5c448552d4298f2402ee444e5))
* **providers:** support default providers by run type ([9f26bb0](https://github.com/viamin/paid/commit/9f26bb049a7d908e7744927a0e8b69ce46b1d491))
* **queue:** user-defined priority labels for issues and PRs ([#838](https://github.com/viamin/paid/issues/838)) ([86661bf](https://github.com/viamin/paid/commit/86661bfb9d88b37bef5b53f4be2a0fcb20688eff))
* **queue:** user-defined priority labels for issues and PRs ([#838](https://github.com/viamin/paid/issues/838)) ([2bf1a95](https://github.com/viamin/paid/commit/2bf1a95c3732552a9cee60d33f8a682e76033e89))
* **reviews:** add OpenAI Codex as a configurable PR review method ([3e3a9ec](https://github.com/viamin/paid/commit/3e3a9ecd4f015e76bd0c59d14ccaa1f45aa2513c))
* **reviews:** add OpenAI Codex as a configurable PR review method ([2c9cb8b](https://github.com/viamin/paid/commit/2c9cb8b6be6746e8b4abe62e88b624e49e1a9c46)), closes [#804](https://github.com/viamin/paid/issues/804)
* **scanner:** add clean signal detection for paid_agent reviews ([#918](https://github.com/viamin/paid/issues/918)) ([c604fc3](https://github.com/viamin/paid/commit/c604fc35ce5e722a79930b4f49e6ef8936f8cc42))
* **scanner:** define post-escalation behavior after max_review_rounds ([#1006](https://github.com/viamin/paid/issues/1006)) ([ef84fa9](https://github.com/viamin/paid/commit/ef84fa935dc996d75fb47b79c6e00f73666be4d4))
* **scanner:** trigger paid_agent reviews automatically via auto-continue loop ([b6d6775](https://github.com/viamin/paid/commit/b6d6775a7e51238dde2324a8313d6f50385f30f6)), closes [#915](https://github.com/viamin/paid/issues/915)
* **settings:** add database CHECK constraints for display limit bounds ([7bcde54](https://github.com/viamin/paid/commit/7bcde542392e56a72b9edbae97d4b2a6c2fc0aac))
* **ui:** add restart button for crashed poll workflows ([abfb7af](https://github.com/viamin/paid/commit/abfb7af6cdd93bf8404eecbc219973dfb33844fe))
* **ui:** add restart button for crashed poll workflows ([e88adab](https://github.com/viamin/paid/commit/e88adab196a6defa0ca8e018fa23472ca06650d2)), closes [#899](https://github.com/viamin/paid/issues/899)
* **workflow-status:** sync workflow status to UI in real time via Turbo Streams ([1513eaf](https://github.com/viamin/paid/commit/1513eafb2f5a90d61c17b925ac0535cc7bd8e981)), closes [#937](https://github.com/viamin/paid/issues/937)
* **workflow:** add OrphanBranchReaperJob to clean up abandoned remote branches ([4d45300](https://github.com/viamin/paid/commit/4d453002b75a9c47416a45c28002d35549feba5e)), closes [#971](https://github.com/viamin/paid/issues/971)


### Bug Fixes

* 1002: fix(scanner): no recovery path when review-goal agent run fails ([#1010](https://github.com/viamin/paid/issues/1010)) ([efdd6b2](https://github.com/viamin/paid/commit/efdd6b2ad7c3045269f0aa33bb275dcb3b5e1b91))
* 1013: Detect and address all bot reviews regardless of configured review type ([#1060](https://github.com/viamin/paid/issues/1060)) ([55a0aaf](https://github.com/viamin/paid/commit/55a0aafd7895a9a46c8bdfff3a5be595868b0a48))
* 1016: feat(prompts): add pre-submission verification checklist to review-goal prompt ([#1022](https://github.com/viamin/paid/issues/1022)) ([cd66860](https://github.com/viamin/paid/commit/cd66860b79a4f4594a22d55f21a9f7802bf71c49))
* 1017: feat(observability): log warning when review-goal agent posts body-only non-clean review ([#1023](https://github.com/viamin/paid/issues/1023)) ([907c2d8](https://github.com/viamin/paid/commit/907c2d823bfd01f3e12c6cbf045a000ef78253ff))
* 1066: P1: scanner can start new PR follow-up runs before outstanding review-bot reviews complete ([#1067](https://github.com/viamin/paid/issues/1067)) ([577d21e](https://github.com/viamin/paid/commit/577d21ee76324ada8223fccf9cc7ee0fe84b900d))
* 692: fix(knowledge): distinguish 'tool unavailable' from 'no results' in collector runs ([#751](https://github.com/viamin/paid/issues/751)) ([a0fba93](https://github.com/viamin/paid/commit/a0fba938fe1321355f51156f9e104a33e2d94856))
* 698: feat(orchestration): conflict detection and resolution for parallel agents ([#758](https://github.com/viamin/paid/issues/758)) ([9944203](https://github.com/viamin/paid/commit/9944203ae51c0dc302c087a3245ee1b99f01da33))
* 701: feat(guardrails): add token usage limits per agent run ([#761](https://github.com/viamin/paid/issues/761)) ([ec4107f](https://github.com/viamin/paid/commit/ec4107f8db70f49a28ff95926a6ce7b2d4d2a123))
* 704: feat(guardrails): implement anomaly detection for agent behavior ([#766](https://github.com/viamin/paid/issues/766)) ([019ab44](https://github.com/viamin/paid/commit/019ab441169de77f4b189adf823d5b4383b15908))
* 705: feat(guardrails): automatic pause and alert system for guardrail violations ([#768](https://github.com/viamin/paid/issues/768)) ([c2aa964](https://github.com/viamin/paid/commit/c2aa964c56f80c3e0d03d062d921514a85e49a9d))
* 707: feat(evolution): random sampling of completed runs for prompt evaluation ([#773](https://github.com/viamin/paid/issues/773)) ([790fe19](https://github.com/viamin/paid/commit/790fe19406476101537c9f2df54cdc18533e4e7c))
* 708: feat(evolution): implement prompt mutation agent ([#772](https://github.com/viamin/paid/issues/772)) ([f250a4b](https://github.com/viamin/paid/commit/f250a4be77563b60845f79eb6c002a62200b692d))
* 722: feat(performance): worker pool tuning and optimization ([#816](https://github.com/viamin/paid/issues/816)) ([ffbc654](https://github.com/viamin/paid/commit/ffbc6542be88625f08bbb8bc4a9b90bf94e9bdf8))
* 864: skip unchanged issues when fetching comments ([#894](https://github.com/viamin/paid/issues/894)) ([82d39db](https://github.com/viamin/paid/commit/82d39dbfb026d0847e12404458bf8b2bf50c9995))
* 865: fix(github-client): add retry middleware to GraphQL connection ([#889](https://github.com/viamin/paid/issues/889)) ([b6c6e45](https://github.com/viamin/paid/commit/b6c6e45f492577070ab3a02d3d88ea3cfa4f4056))
* 873: perf(quality-metrics): reduce DelayedHumanFeedbackCollectionJob sweep scope ([#881](https://github.com/viamin/paid/issues/881)) ([51480db](https://github.com/viamin/paid/commit/51480db206468dbf1a72ff66307392f348e58b7f))
* 874: feat(models): add tier metadata and per-provider tier configuration ([#880](https://github.com/viamin/paid/issues/880)) ([1d598e0](https://github.com/viamin/paid/commit/1d598e09fc8e7b11fee5dab00fed240aac64622f))
* 895: Draft review follow-up runs retry indefinitely when timing out silently ([#896](https://github.com/viamin/paid/issues/896)) ([06914f1](https://github.com/viamin/paid/commit/06914f11930fbc5b048ec5b4fb86d5f796858210))
* 906: PR body rewriter-nil fallback dumps raw agent stdout instead of a templated description ([#907](https://github.com/viamin/paid/issues/907)) ([914280c](https://github.com/viamin/paid/commit/914280c5e874198317392c31a6f70b1c0e6cb794))
* 974: Auto-pick should skip issues with existing PRs or active agent runs ([#1020](https://github.com/viamin/paid/issues/1020)) ([5301098](https://github.com/viamin/paid/commit/5301098a68f10dcda67680661ff23a16bd880819))
* add missing frozen_string_literal comment to output_sanitizer.rb ([2507540](https://github.com/viamin/paid/commit/25075408648a3b5888cabe2b13aa1cc3d4d828af))
* add missing reviewer_login field to manual review settings form ([780e07d](https://github.com/viamin/paid/commit/780e07d285bbd053d03722e0652f9cc39e0ee2d4))
* add missing reviewer_login field to manual review settings form ([ae4b956](https://github.com/viamin/paid/commit/ae4b956180efb76615516a363e19047882144f02))
* **agent-runs:** add HTTP 429/too many requests to timeout rate-limit patterns ([bc2f8a6](https://github.com/viamin/paid/commit/bc2f8a68c0a7c40f9147a075641cb01e88d6a4ba))
* **agent-runs:** address binary output review feedback ([2c9f55c](https://github.com/viamin/paid/commit/2c9f55c28bc5fc29a426990f4bbf94a7b7665fbb))
* **agent-runs:** address final PR review feedback for clarity and test coverage ([49d3d9a](https://github.com/viamin/paid/commit/49d3d9ab047985dd36e36993d4eb15d790e4228d))
* **agent-runs:** address PR review feedback for input validation and code clarity ([1bfa872](https://github.com/viamin/paid/commit/1bfa872a4ce652932cf81b43a2542c0f27aa8d6d))
* **agent-runs:** address PR review feedback for multi-select table ([c5763e7](https://github.com/viamin/paid/commit/c5763e75663cfaab7a7a0bef973f530473f39dcc))
* **agent-runs:** address PR review feedback for priority select input ([f43e0c3](https://github.com/viamin/paid/commit/f43e0c3660d30cd5a3a3f0781c4413913af009b9))
* **agent-runs:** address PR review feedback for scope validation ([fbfcedd](https://github.com/viamin/paid/commit/fbfcedd2153d596d180f3d58ccd1df3b386ea159))
* **agent-runs:** address PR review feedback for server-side validation and code quality ([8e48360](https://github.com/viamin/paid/commit/8e483604806010ec231c2af11fafdc6ab0c5c0a9))
* **agent-runs:** address remaining PR review feedback for priority select ([8de7ac6](https://github.com/viamin/paid/commit/8de7ac642bd88181dcc0b5152c406342fe17d3c9))
* **agent-runs:** address remaining PR review feedback for robustness and UX ([5f596c6](https://github.com/viamin/paid/commit/5f596c6f9d13e3e83939b3cff0bae99b71e143a2))
* **agent-runs:** address remaining review comments on timeout reclassification ([d96b8b7](https://github.com/viamin/paid/commit/d96b8b70295b9b9e1576fa0cf0be615b1db886b2))
* **agent-runs:** address review feedback on timeout reclassification ([8359ce4](https://github.com/viamin/paid/commit/8359ce48f02438206ed62d51dc29bd6a47f3b8ac))
* **agent-runs:** aggregate LATERAL join labels and use LEFT JOIN for projects ([5f6905c](https://github.com/viamin/paid/commit/5f6905c913e6dd64f286fa77d773c9cd9bec18b8))
* **agent-runs:** anchor issue-ref regex to prevent in-token matches ([1d82a6b](https://github.com/viamin/paid/commit/1d82a6bf1d8570577f93a6d14ac4176bc02ae933))
* **agent-runs:** bound timeout log scan and tighten phrase matching ([5ea9b21](https://github.com/viamin/paid/commit/5ea9b210d9e5a6d511d80f9602560f1bb3b278f7))
* **agent-runs:** clarify automatic run provider refresh semantics ([896c1f7](https://github.com/viamin/paid/commit/896c1f706c6ca40c06b0e777c44ab016ef2050b2))
* **agent-runs:** classify quota timeouts as rate limits ([7987ae3](https://github.com/viamin/paid/commit/7987ae3f3c2e42572091c551f71bd5831c269877))
* **agent-runs:** classify quota timeouts as rate limits ([a38ca94](https://github.com/viamin/paid/commit/a38ca94410ffa9e4933375c95428ee5f6818cffa))
* **agent-runs:** clear container_id before Docker cleanup and lazy-evaluate stale count ([8e9c135](https://github.com/viamin/paid/commit/8e9c1355f5afea0ceafbe4afeb3c7da33da64132))
* **agent-runs:** document sanitizer nil fast path ([5aff397](https://github.com/viamin/paid/commit/5aff39701c135d338f17a1341f15ff64058426d1))
* **agent-runs:** eager-load PRs and pass locals to shared partial ([7ce0d6c](https://github.com/viamin/paid/commit/7ce0d6c99aabb6a2591c8788c47cc01aae17db02))
* **agent-runs:** harden output normalization ([b0593eb](https://github.com/viamin/paid/commit/b0593eb8de3f9c7f9168b5b8bea99d88be2ce478))
* **agent-runs:** honor provider routing and primary selection ([845f09b](https://github.com/viamin/paid/commit/845f09b3bba0c3fac6f703d9ccb7d9d21e5db20a))
* **agent-runs:** honor provider routing and primary selection ([a08c32f](https://github.com/viamin/paid/commit/a08c32fd278a976864de7847d9efcdccfbf76acf))
* **agent-runs:** ignore echoed prompts in rate limit detection ([e92d047](https://github.com/viamin/paid/commit/e92d047954c7b5d12c4e2d974a56cf4f3ca394d0))
* **agent-runs:** ignore echoed prompts in rate limit detection ([2db7fa1](https://github.com/viamin/paid/commit/2db7fa16eb6a9ff5b87138714540fbdef957c8c4))
* **agent-runs:** include stale pending manual cleanup ([7d3df48](https://github.com/viamin/paid/commit/7d3df48a44ef553a8fce00f601ac749bb14d90dd))
* **agent-runs:** link PRs and review comments in project and index tables ([b2225c8](https://github.com/viamin/paid/commit/b2225c80a5f59fc3375bff2cc8db8276a0370700))
* **agent-runs:** match qualified owner/repo#NNN refs in scope validation ([e894516](https://github.com/viamin/paid/commit/e8945163a9f8c8da31595bb8186d93231d51a3ae))
* **agent-runs:** merge main into priority select PR ([be5cfed](https://github.com/viamin/paid/commit/be5cfed64d3a1ce7347746d86968778caff22572))
* **agent-runs:** move GitHub label sync outside database transaction ([e940e24](https://github.com/viamin/paid/commit/e940e24eac0055cf70400dc413a884c0762e69c1))
* **agent-runs:** normalize binary agent output ([9854c03](https://github.com/viamin/paid/commit/9854c038aac8975d1879927360e14dea6a128f70))
* **agent-runs:** normalize binary agent output ([8c2b8c4](https://github.com/viamin/paid/commit/8c2b8c4dbe909a0e59a0b08c13072bedebc65a3b))
* **agent-runs:** normalize binary output fallback paths ([1d3f497](https://github.com/viamin/paid/commit/1d3f497167bcd9780e303bd8df9bf1adccfd11a6))
* **agent-runs:** normalize binary output fallback paths ([6183f2f](https://github.com/viamin/paid/commit/6183f2f45fe830488cd533caeb79ef446f692c33))
* **agent-runs:** PR review table invisible on trigger form ([cdc1111](https://github.com/viamin/paid/commit/cdc1111d05a5d9bf61f0b8a9bda309a5adf4b764))
* **agent-runs:** PR review table invisible when selecting PR Code Review goal ([62ad4d6](https://github.com/viamin/paid/commit/62ad4d6145653654339497c05cbf5a6e92f54072))
* **agent-runs:** preserve repo qualifier when matching issue refs in scope validation ([5a41a4c](https://github.com/viamin/paid/commit/5a41a4ce4f21816d0adca89165c71aab9535b34a))
* **agent-runs:** preserve utf-8 output bytes ([16ab986](https://github.com/viamin/paid/commit/16ab9869a13820fa318630486dd130760d66f4dd))
* **agent-runs:** refresh provider selection and require explicit provider models ([20e3378](https://github.com/viamin/paid/commit/20e3378b38c84c5dca859cd8e063c519b89e5c09))
* **agent-runs:** refresh provider selection and require explicit provider models ([4f8cb4b](https://github.com/viamin/paid/commit/4f8cb4bc634fee0f320f032dabbc322331b36a11))
* **agent-runs:** remove rails helper asset bootstrap ([f5ccfdc](https://github.com/viamin/paid/commit/f5ccfdccd4c8a60de128946a194c4e2d2098b849))
* **agent-runs:** require local-repo match for own-issue detection and normalize case in qualifier comparisons ([0ab0810](https://github.com/viamin/paid/commit/0ab0810fcf99a2bf7e5224a38a1d888fa28f90b0))
* **agent-runs:** rescue validate_summary_scope errors and remove nil worktree_path from provision log ([2ab572c](https://github.com/viamin/paid/commit/2ab572cfbdaa7f7ebbbc68ecccd256b16c40fd78))
* **agent-runs:** restore iterations guard for non-no_output statuses in draft breaker ([c7cac50](https://github.com/viamin/paid/commit/c7cac5086dd18526ac4c4f080c5abed38f49ef1b))
* **agent-runs:** restore test setup safeguards ([aec69cd](https://github.com/viamin/paid/commit/aec69cd3caefb0c83ef4a082b7a1b9dd4a49ca7b))
* **agent-runs:** revert whitespace-only db/schema.rb changes per review ([04c8338](https://github.com/viamin/paid/commit/04c8338fcf22175f18d5ba22fdce588f14a55f6a))
* **agent-runs:** sync priority labels to GitHub and reduce schema.rb noise ([3d4c5bb](https://github.com/viamin/paid/commit/3d4c5bb83a293ff691846dc9f398b799f4cea564))
* **agent-runs:** sync provider default with selected goal ([19b7b70](https://github.com/viamin/paid/commit/19b7b70e7768c82601c4f2f9ce471ebf8a9264de))
* **agent-runs:** unify poll-triggered scheduling behind queue ([#806](https://github.com/viamin/paid/issues/806)) ([f8c95a8](https://github.com/viamin/paid/commit/f8c95a8c19d81add8b0a932eb6b9e7c92ea06cab))
* **agent-runs:** use safe_github_url? guard for external links in project views ([9191174](https://github.com/viamin/paid/commit/9191174e08f332c382b196032ba19cfd15da033b))
* **agent-runs:** wrap priority label update in transaction with agent run creation ([d12b069](https://github.com/viamin/paid/commit/d12b0695c2d99a605e3af117539eecfe9ac9900e))
* **auto-merge:** address remaining review feedback ([0c8320c](https://github.com/viamin/paid/commit/0c8320c8fd2e6125c631f30c86cbfbc8b24cf48a))
* **auto-merge:** address review feedback on file-diff heuristic ([009087a](https://github.com/viamin/paid/commit/009087af034788d27904e1efcfff38e5884a2e65))
* **auto-merge:** address review feedback on HEAD commit verification ([ce38419](https://github.com/viamin/paid/commit/ce38419f23de2071ab0f7b578adb751df7b7b477))
* **auto-merge:** address second-round review feedback on HEAD commit verification ([6029f7f](https://github.com/viamin/paid/commit/6029f7f6521734c6af1e015bfebe2869c325e6d7))
* **auto-merge:** check affected files when clearing body-only review feedback ([2a5a2d6](https://github.com/viamin/paid/commit/2a5a2d611bf4974d8179d8c3a72f675c7151a1b2)), closes [#935](https://github.com/viamin/paid/issues/935)
* **auto-merge:** require clean re-review on HEAD commit for body-only bot clearance ([b6f7492](https://github.com/viamin/paid/commit/b6f74924ba70eeba93a89dec013b750ad1040e4a)), closes [#934](https://github.com/viamin/paid/issues/934)
* **containers:** add defense-in-depth against artifact commits ([#1061](https://github.com/viamin/paid/issues/1061)) ([c2c74f8](https://github.com/viamin/paid/commit/c2c74f8c08540e80732db7ea8bd3daf6e5045926))
* **credentials:** add paid-code-reviewer github app private key ([8e527e5](https://github.com/viamin/paid/commit/8e527e51655826f3e1edf15b84822fb18d27c720))
* **credentials:** add paid-code-reviewer github app private key ([577fb50](https://github.com/viamin/paid/commit/577fb503d46dedd366adc573a97550dbeb3703cf))
* **dashboard:** show resolved provider names ([#775](https://github.com/viamin/paid/issues/775)) ([1d83fdb](https://github.com/viamin/paid/commit/1d83fdb0e78ae39b20eba83b8c4ac8fc2aecde47))
* **dev-cleanup:** also short-circuit InfiniteLoopError + add predicate specs ([4255974](https://github.com/viamin/paid/commit/4255974bbaa88d2c77d215fde67d9e0d675e0a97))
* **dev-cleanup:** clarify reload contract in cleanup guard comment ([d4ed0d7](https://github.com/viamin/paid/commit/d4ed0d7c5130e7a32c5bb8e60016baff431411f7))
* **dev-cleanup:** don't trip provider circuit breaker when cleanup kills runs ([1ced061](https://github.com/viamin/paid/commit/1ced0617d2259c14441c79a687762dff7bc6003f))
* **dev-cleanup:** don't trip provider circuit breaker when cleanup kills runs ([a4f00b0](https://github.com/viamin/paid/commit/a4f00b05f22a93584be4a176e944bb880bf2d953)), closes [#931](https://github.com/viamin/paid/issues/931)
* **dev-cleanup:** skip ProcessRunQueueJob dispatch on cleanup-cancelled timeouts ([8623d53](https://github.com/viamin/paid/commit/8623d537399703ac1acc954a8cd91137cb66bac7))
* **dev:** add --detach mode and clean stale overmind tmp dirs ([9689acc](https://github.com/viamin/paid/commit/9689acc9ec197e747286c452ab734bbfff266ada))
* **dev:** add --detach mode and clean stale overmind tmp dirs ([e04268b](https://github.com/viamin/paid/commit/e04268bedaa1d35247466e0e564bca9d01af3a0a))
* **dev:** add supervisor diagnostics for overmind shutdowns ([bc89a29](https://github.com/viamin/paid/commit/bc89a2923acec23628d7157ec0a9edb1acf966aa))
* **dev:** add supervisor diagnostics for overmind shutdowns ([a2a65c6](https://github.com/viamin/paid/commit/a2a65c692cef108a7997866cb4cce7a3ce5338bd))
* **dev:** address PR review feedback for detach mode ([c92c171](https://github.com/viamin/paid/commit/c92c1710d832826518c9e65a14ddeef55322d155))
* **dev:** clarify detached PID is setsid wrapper and document bin/setup UX change ([c2d7d81](https://github.com/viamin/paid/commit/c2d7d81385dd5e0b6c9342fa1a16672a455bc6a3))
* **devcontainer:** configure KiloCode auto-approval inside container only ([110f647](https://github.com/viamin/paid/commit/110f647d3348fedea6a6ddc4147095fd2df6a5fd))
* **devcontainer:** configure KiloCode auto-approval inside container only ([74a5edc](https://github.com/viamin/paid/commit/74a5edc5cc6cbc476ebd33e976ae070c5ab24541)), closes [#861](https://github.com/viamin/paid/issues/861)
* **devcontainer:** enable init for zombie reaping ([f15d0d3](https://github.com/viamin/paid/commit/f15d0d38c9e6fd91f65f461d321daf0067703776))
* **dev:** harden auto-update overmind recovery ([cd10011](https://github.com/viamin/paid/commit/cd10011b0c25d8377f334010a6f5dc16cb5a425a))
* **dev:** harden auto-update overmind recovery ([333bf89](https://github.com/viamin/paid/commit/333bf89170564ee6ae68198d42367f655259d6b8))
* **github-client:** recent_issue_comments must follow Link: last for newest comments ([50165cf](https://github.com/viamin/paid/commit/50165cfa075534969280b12b6d501cce78fa9172))
* **github-sync:** address review feedback for fetch_issues_activity ([4b32f67](https://github.com/viamin/paid/commit/4b32f679bc61c3e7bc7ad2dc36852ceb74055b40))
* **github-sync:** address review feedback for fetch_issues_activity ([f579056](https://github.com/viamin/paid/commit/f5790567092aa506d9d1d1846ea163c3539441a5))
* **github-sync:** address review feedback for incremental issue fetching ([ed1a110](https://github.com/viamin/paid/commit/ed1a1109d77f23cc3e55f7fddaa7309ac12c1cda))
* **github-sync:** address review feedback on rate-limit rescue narrowing ([9b8e0ff](https://github.com/viamin/paid/commit/9b8e0ff8b7f48782ba36f4b9c4d0d949b1bb19f8))
* **github-sync:** advance truncated incremental watermark for forward progress ([930fa02](https://github.com/viamin/paid/commit/930fa0223dacecf5791a832b4c53927f00dc541d))
* **github-sync:** drop unrelated schema drift and probe before declaring truncation ([a0cee1b](https://github.com/viamin/paid/commit/a0cee1b162a654e17957ec6b95c90aacc3e5c22e))
* **github-sync:** exclude closed issues from downstream processing and guard truncated watermark ([94d3a1f](https://github.com/viamin/paid/commit/94d3a1f7ed28aa41f70494ff542091db55d2246b))
* **github-sync:** merge main, address review feedback on rate-limit checks ([8d27057](https://github.com/viamin/paid/commit/8d270575a4729893060b500e1a2e8d57c9b3285b))
* **github-sync:** merge main, handle rate-limit exhaustion gracefully mid-scan ([9cdc081](https://github.com/viamin/paid/commit/9cdc0816b818688a0ea170c886bf94fe6b2244a0))
* **github-sync:** merge main, remove committed yarn cache artifacts ([7ddbee1](https://github.com/viamin/paid/commit/7ddbee18964f9bb468220579fbcdec13c44c026a))
* **github-sync:** merge main, resolve conflict in github_client.rb ([bd7b4de](https://github.com/viamin/paid/commit/bd7b4dec14a75e57c5a4044252bb6714b8052e63))
* **github-sync:** merge main, resolve conflict in scan_paid_prs_activity.rb ([0506796](https://github.com/viamin/paid/commit/0506796b116523d502b20990acfa3f5a7026cb67))
* **github-sync:** move rate-budget check after active-run guard in scan_pr ([38e8ff5](https://github.com/viamin/paid/commit/38e8ff5ac8577c5a6796be20500289b6ecae5cb9))
* **github-sync:** re-scan unchanged open issues during incremental fetches ([3bf39c0](https://github.com/viamin/paid/commit/3bf39c0c0cb8b447a8efcd0e62d4aeebb37ec8b9))
* **github-sync:** resolve merge conflict and fix truncation probe per_page ([9f1f9f0](https://github.com/viamin/paid/commit/9f1f9f0b8f7da07ceb37b7baf5b915940f2d2da2))
* **github-sync:** resolve merge conflict with origin/main ([c1ccf03](https://github.com/viamin/paid/commit/c1ccf035b09c433c27be1b24ceb179a311bc5b01))
* **github-sync:** resolve merge conflicts and address review feedback ([c0173b0](https://github.com/viamin/paid/commit/c0173b02abbf4e5d17b175c53733d3b913be4a31))
* **github-sync:** resolve merge conflicts and defer rate-budget guard past phase short-circuits ([3dbfabf](https://github.com/viamin/paid/commit/3dbfabf35d20979d72b446204893f0115175d51b))
* **github-sync:** separate rate-limit probe errors from low quota in check_rate_budget! ([958af0a](https://github.com/viamin/paid/commit/958af0aa7e0c48b2ae5aee29f601342620b3d44b))
* **github-sync:** use inclusive boundary for truncated incremental watermark ([b66f0c4](https://github.com/viamin/paid/commit/b66f0c40d0e23339ffce966f4edb5c9ab0f3a5e4))
* **knowledge:** handle content_hash collisions across different scope_paths ([e550699](https://github.com/viamin/paid/commit/e550699957c32a61acebff58612b19e6f398a37d)), closes [#982](https://github.com/viamin/paid/issues/982)
* **knowledge:** handle EOF in archive_in_stream chunker ([e951f2d](https://github.com/viamin/paid/commit/e951f2d7488a53f27ede2ad8a9fc745eeb3e9546))
* **knowledge:** handle EOF in archive_in_stream chunker ([79f214b](https://github.com/viamin/paid/commit/79f214ba5ce744bb9e2baed6d2a6f473a0858886))
* **knowledge:** install gems before routes collection in container ([20d501e](https://github.com/viamin/paid/commit/20d501e5743d52f2a14dc16ba9ec5652e803ccaa)), closes [#983](https://github.com/viamin/paid/issues/983)
* **knowledge:** restore network isolation for collector containers ([b277aa5](https://github.com/viamin/paid/commit/b277aa58b206ea1808841262d1f139f02e43890d))
* **notifications:** add retry limit to RecordNotUnique rescue and expand Resolve specs ([bf462c6](https://github.com/viamin/paid/commit/bf462c63a762280953204d3018282bcc96e717b2))
* **notifications:** address code review feedback for notification center ([3cd3444](https://github.com/viamin/paid/commit/3cd34442ea3cc35db4ed26c8ba81ac7ac3ac6165))
* **notifications:** address PR review feedback — perf, bugs, and schema noise ([6cb7f73](https://github.com/viamin/paid/commit/6cb7f73f07845c65f17756ae82da1293cfe00519))
* **notifications:** address review feedback on helper duplication and mark_all_read UI ([6c5b9c6](https://github.com/viamin/paid/commit/6c5b9c6383e43b1ad6c18140a2f1219789c630d7))
* **notifications:** clear read_at on re-publish so escalated notifications appear as unread ([47110b0](https://github.com/viamin/paid/commit/47110b078a8e344a6eb900657b657f9a45590cb4))
* **notifications:** compute broadcast counts server-side and add NULL-safe dedup index ([b60b46f](https://github.com/viamin/paid/commit/b60b46ff640bd503081a2e5e5849fcac00db797a))
* **notifications:** handle race condition in Publish and add on_delete nullify for user FK ([1bcae05](https://github.com/viamin/paid/commit/1bcae05e4032d29963df321481e864773dceb58a))
* **notifications:** merge main and reject protocol-relative urls ([1476df9](https://github.com/viamin/paid/commit/1476df9c308a44b5c0ec0b6bbc64c5e2c15e5518))
* **notifications:** scope notifications to user, fix dedup index ([939021f](https://github.com/viamin/paid/commit/939021fc5a740a40421a54ad912e96c562e5922a))
* **notifications:** validate nav_section, preserve filters in pagination, update nav badges on mark-all-read ([1806df8](https://github.com/viamin/paid/commit/1806df8cd2aed8a13676a1fac9dcae86173f573f))
* permit reviewer_login in manual review strong params ([11a0a2f](https://github.com/viamin/paid/commit/11a0a2f645aa7a020f1b1537ebbae6cca47a35cd))
* **poll-workflow:** preserve old non-critical path when patch guard is absent ([5f9cdd1](https://github.com/viamin/paid/commit/5f9cdd154301079a56d0de72cd7842d7e907e829))
* **pr-review:** address draft followup review feedback ([d10eccc](https://github.com/viamin/paid/commit/d10ecccc3158d4cb0d100574cc0de5467b8cb638))
* **pr-review:** address remaining review feedback on draft followup tracking ([8394c27](https://github.com/viamin/paid/commit/8394c2745880c918e3501d30610161b4cd435b62))
* **pr-review:** address review feedback on draft followup tracking ([6dcc7c6](https://github.com/viamin/paid/commit/6dcc7c63c8d2622438300b3ace36b8a767c71707))
* **pr-review:** address review feedback on draft followup tracking ([1eb656c](https://github.com/viamin/paid/commit/1eb656c268d6a5626f7506949b5424d6e88586b1))
* **pr-review:** address unresolved review feedback on PR [#807](https://github.com/viamin/paid/issues/807) ([5382bf9](https://github.com/viamin/paid/commit/5382bf94f032a2e378738186fa135a4bf3a0ef94))
* **pr-review:** count only successful draft followups ([8bc314f](https://github.com/viamin/paid/commit/8bc314f483acb05f1fb44b1a6c27e030ce41aaaf))
* **pr-review:** count only successful draft followups ([ed9dee7](https://github.com/viamin/paid/commit/ed9dee732a8b6762a22d5c4ee4cdc1c13cf6cc3d))
* **pr-review:** detect codex body-only reviews as unaddressed feedback ([c90af31](https://github.com/viamin/paid/commit/c90af312089e229e92462d146b9cb05214c772e6))
* **pr-review:** detect codex body-only reviews as unaddressed feedback ([db9fb10](https://github.com/viamin/paid/commit/db9fb1088969976870c617ba57cd4781496a3b38)), closes [#901](https://github.com/viamin/paid/issues/901) [#807](https://github.com/viamin/paid/issues/807)
* **pr-review:** detect codex clean signal posted as an issue comment ([7e32002](https://github.com/viamin/paid/commit/7e32002348b0b6e40b1c81818d760a0d3a766f5b))
* **pr-review:** detect codex clean signal posted as an issue comment ([84c1e03](https://github.com/viamin/paid/commit/84c1e03b8ae9638bc24b60fd3186322037d26c61))
* **pr-review:** patch draft followup replay path ([617fab2](https://github.com/viamin/paid/commit/617fab21e1abba5c95c24bee2739087f8ddcf3fe))
* **pr-review:** prevent double-counted draft rounds for legacy runs ([6cef60d](https://github.com/viamin/paid/commit/6cef60d677a227f8cb042c9045a604a74ec71625))
* **pr-review:** record draft review round only after successful completion ([4f13051](https://github.com/viamin/paid/commit/4f13051c37c19072ee5c67ddfddbb4d0f2426767))
* **pr-review:** remove private keyword that broke subclass method visibility ([7ef2376](https://github.com/viamin/paid/commit/7ef2376cc8bfffa7855cae794180190225bad3ff))
* **pr-review:** restore missing foreign keys in schema.rb ([7f9c61c](https://github.com/viamin/paid/commit/7f9c61ce113f969e76146a8787a5f1c428aa87be))
* **pr-review:** restrict codex clean-comment override to body-only-only configs ([2ec5483](https://github.com/viamin/paid/commit/2ec5483048f1f825d427666eb5a45ebdd2e061b7))
* **pr-review:** serialize draft followups through queue ([abd3e4f](https://github.com/viamin/paid/commit/abd3e4f483c477e123b51728170bf856753ab50d))
* **pr-scanner:** address review feedback on recent_issue_comments ([f9f234b](https://github.com/viamin/paid/commit/f9f234b20dad81f7ef110f24b348da74f661b730))
* **pr-scanner:** address review feedback on recent_issue_comments ([0eb66ff](https://github.com/viamin/paid/commit/0eb66ffc7afd8617983a811d3088222f1f6e6cba))
* **pr-scanner:** address review feedback on skip-unchanged-PRs ([39c32e2](https://github.com/viamin/paid/commit/39c32e2e2e11e24cb46cd39f3fecdd1c54b14e91))
* **pr-scanner:** address review feedback on skip-unchanged-PRs ([f19e4eb](https://github.com/viamin/paid/commit/f19e4eb0b30284d38b96e8ad8d642d0245653c67))
* **pr-scanner:** clean up schema.rb formatting noise from merge ([0c5e8b7](https://github.com/viamin/paid/commit/0c5e8b776f62fe70fb4aa66e72dabd78735b3747))
* **pr-scanner:** defer last_pr_scan_at stamp when triggers are emitted ([6b2885a](https://github.com/viamin/paid/commit/6b2885a41c6fe7f86724235decd882c723b7107b))
* **pr-scanner:** emit actionable triggers on partial API failures in ready phase ([b0b5524](https://github.com/viamin/paid/commit/b0b5524d5bd80506ce5d819c1c7fe051ab7d3607))
* **pr-scanner:** fall back to full pagination when cutoff exceeds recent page ([16dacd7](https://github.com/viamin/paid/commit/16dacd71e75f45e67fbc96b9bf3f944506324856))
* **pr-scanner:** fall back to full pagination when cutoff exceeds recent page ([615cebf](https://github.com/viamin/paid/commit/615cebf0c706aefc8b98f6f5ed128f87e2b3321e))
* **pr-scanner:** honor codex clean comments despite info posts ([#1063](https://github.com/viamin/paid/issues/1063)) ([5b99b32](https://github.com/viamin/paid/commit/5b99b32a3c7c40b239c92c8b66c7aeb1dd7c86d8))
* **pr-scanner:** only update last_pr_scan_at after successful scan ([f910826](https://github.com/viamin/paid/commit/f910826ad444c922a36a2100b65fbb615921aea8))
* **pr-scanner:** resolve merge conflicts with main ([8949495](https://github.com/viamin/paid/commit/894949550e3ff07be8c6c6daacdbd22b81bb3107))
* **pr-scanner:** scan full recent-comments page for conversation triggers ([ebf7ae7](https://github.com/viamin/paid/commit/ebf7ae79c2d9fe1b1509b1f535a7aecf8c4d4362)), closes [#870](https://github.com/viamin/paid/issues/870)
* **pr-scanner:** skip last_pr_scan_at stamp when ready/escalated API calls fail ([68888e0](https://github.com/viamin/paid/commit/68888e03b46b373337a223d3ec0f2569316549f9))
* **pr-scanner:** stamp last_pr_scan_at after any completed scan and clean schema.rb ([76ed4d2](https://github.com/viamin/paid/commit/76ed4d237f90df7f5617c610f6282aff14932ad5))
* **projects:** add startup validation and logging for review method badges ([4ad9b25](https://github.com/viamin/paid/commit/4ad9b25726340cdb1889c5145c499a3fffc6d42e))
* **projects:** address PR review feedback for priority label fields ([c19de5e](https://github.com/viamin/paid/commit/c19de5e618438977eb6f264176b73a1c29a4eade))
* **projects:** address PR review feedback for priority label fields ([1b8943c](https://github.com/viamin/paid/commit/1b8943c0df48bf7a3e7313f9a0d0f262c33e1ac6))
* **projects:** address review feedback on review method badges ([914be1b](https://github.com/viamin/paid/commit/914be1bf7f554233f005a78b6768fb3c106e87ba))
* **projects:** drop unsafe container_timeout_seconds backfill and correct schema version ([8ae2357](https://github.com/viamin/paid/commit/8ae2357aeb43f1d0b568a171a72a2ce7ee206e03))
* **projects:** expose security automation settings ([#765](https://github.com/viamin/paid/issues/765)) ([e0a0f6b](https://github.com/viamin/paid/commit/e0a0f6b8fede7a763eeb23069264346ff9aff9a6))
* **projects:** permit inherit_priority_labels in strong params ([#838](https://github.com/viamin/paid/issues/838)) ([0fa618a](https://github.com/viamin/paid/commit/0fa618a55e4caf285bf9e8c41f4682013c169449))
* **projects:** split guard clause and logging in review_method_badge ([475170c](https://github.com/viamin/paid/commit/475170c03f981693258ffbd45af42890ba0215e5))
* **prompts:** address code review findings on extract fallback and DRY service sections ([9e72175](https://github.com/viamin/paid/commit/9e721756a2624a872e0324c18f1403c46585b671))
* **prompts:** address code review findings on prompts migration ([c5ca7a3](https://github.com/viamin/paid/commit/c5ca7a33d4a6ffbff2d1088dbd0804c69217081f))
* **prompts:** address code review findings on prompts migration ([9db8508](https://github.com/viamin/paid/commit/9db8508ff42f3f026df712526e1269311c095dbb))
* **prompts:** address second round of code review findings ([cb4f0cd](https://github.com/viamin/paid/commit/cb4f0cde65043a476f531c25df40281a040ee45b))
* **providers:** align required model messaging and specs ([7e410f2](https://github.com/viamin/paid/commit/7e410f23c05fc0cb609b209716e3c9c3356210c9))
* **providers:** preserve goal defaults on invalid params ([b262922](https://github.com/viamin/paid/commit/b26292290d0767189810f1890d76bbbd2de3649b))
* **providers:** repair Copilot CLI container integration ([#786](https://github.com/viamin/paid/issues/786)) ([c8fe929](https://github.com/viamin/paid/commit/c8fe929572fc435881fe1857c7b736a697d3c062))
* **providers:** restore codex sandbox bypass for test agent ([8c9e9f6](https://github.com/viamin/paid/commit/8c9e9f6ec9bb72e32a51d9dbbf5810aa90b9d6bf))
* **providers:** restore codex sandbox bypass for test agent ([69f90cd](https://github.com/viamin/paid/commit/69f90cd40cfb398834f14b037333bf151a82c3f4))
* **providers:** sync test agent status with rate limit results ([98dad69](https://github.com/viamin/paid/commit/98dad6924f124e379365fc64b0ea5fcddd4e1a5b))
* **providers:** sync test agent status with rate limit results ([0938a58](https://github.com/viamin/paid/commit/0938a58e487f985cabf0835b84afe5564e146c72))
* **quality-metrics:** address review feedback on batch reaction fetching ([3cd9265](https://github.com/viamin/paid/commit/3cd92658abf3f8612b4a21055d95d84f4a0749e2))
* **quality-metrics:** address review feedback on batch reaction fetching ([abd8d2a](https://github.com/viamin/paid/commit/abd8d2aabb0c8b1bb654329dd734951c4360e37b))
* **quality-metrics:** log truncation warnings for paginated GraphQL connections ([a3d65b4](https://github.com/viamin/paid/commit/a3d65b4a7c067423f554a3f9c991a5d9b251dccd))
* **quality-metrics:** raise GraphQL errors and paginate overflowing reactions ([3d15df0](https://github.com/viamin/paid/commit/3d15df0a8c88d08e806b5ec80002e0d4deecd01d))
* **quality-metrics:** remove unused reviewComments field from GraphQL query ([9e99b2a](https://github.com/viamin/paid/commit/9e99b2a2d07012c9a03634f7e10dee15fba85d0f))
* **quality-metrics:** rename max_comments to max_threads and rescue per-comment fallback failures ([1e8e005](https://github.com/viamin/paid/commit/1e8e00556f5d54739946c26beb7ac2db8c0e4326))
* **quality:** address PR review feedback for webhook feedback lookup ([21131a7](https://github.com/viamin/paid/commit/21131a795c6ce40212d097b8046a60bb6d03a51b))
* **quality:** document intentional review-goal fallback scope and index gap ([f9b6986](https://github.com/viamin/paid/commit/f9b69863a8fa55459cb47c044652d85d8097f067))
* **quality:** find review-goal agent runs in webhook feedback lookup ([e34c099](https://github.com/viamin/paid/commit/e34c0995bc00769b9bf7ea6260960d2cff743592)), closes [#943](https://github.com/viamin/paid/issues/943)
* **queue:** address PR review feedback for priority labels ([#838](https://github.com/viamin/paid/issues/838)) ([9585f70](https://github.com/viamin/paid/commit/9585f7005e2dbe09391daed498954f5e2bae8de3))
* **queue:** address review feedback round 8 ([#838](https://github.com/viamin/paid/issues/838)) ([cd1c72e](https://github.com/viamin/paid/commit/cd1c72e51c6fd1f463c236c0efccf24528b0506f))
* **queue:** batch-load source PR rows + permit priority_labels ([#838](https://github.com/viamin/paid/issues/838)) ([78d6a1a](https://github.com/viamin/paid/commit/78d6a1a925bab4dcf6ace18513dd4fe8c8a79a3b))
* **queue:** document SQL OR semantics + precise PR preload ([#838](https://github.com/viamin/paid/issues/838)) ([2e0e4e2](https://github.com/viamin/paid/commit/2e0e4e20fe2453a7130fcb6c4dbc79fd61918b1a))
* **queue:** index issues for queue SQL + decouple priority inheritance from auto-add ([#838](https://github.com/viamin/paid/issues/838)) ([1dda574](https://github.com/viamin/paid/commit/1dda574b0088fb01b8a36baae1a0f1edc248e00c))
* **queue:** inherit priority labels in aggregated PR + recovery ([#838](https://github.com/viamin/paid/issues/838)) ([77776f6](https://github.com/viamin/paid/commit/77776f6d1284686298bcbe65f139caea4e667129))
* **queue:** memoize tier lookup and treat null label values as unset ([#838](https://github.com/viamin/paid/issues/838)) ([978b951](https://github.com/viamin/paid/commit/978b951e92bcda97dbabf44aa143d62f11758729))
* **queue:** preload priority-label sources on project dashboard ([#838](https://github.com/viamin/paid/issues/838)) ([f417352](https://github.com/viamin/paid/commit/f4173527330cfbae15152d257e0616a5a11159d7))
* remove .yarn-cache-v2/ build artifacts from repository ([0f3fb27](https://github.com/viamin/paid/commit/0f3fb272c5e18b2328b43243744efe1d865ff8b4))
* resolve merge conflicts with main for LATERAL join optimization ([a5354bc](https://github.com/viamin/paid/commit/a5354bcd814d72e4549c7eeec63010102c6b4b13))
* **review-runs:** prevent timed-out review-goal runs from re-triggering indefinitely ([6043876](https://github.com/viamin/paid/commit/604387667857127b65a076c0c634a8628bf3f795)), closes [#830](https://github.com/viamin/paid/issues/830)
* **reviews:** address PR review feedback on blocking review signals ([85ce5fb](https://github.com/viamin/paid/commit/85ce5fb4c971d1b65c719bda3db37145c0883e69))
* **reviews:** align manual_review_complete? and blocking_approval_timestamps with configured reviewer ([3f4f25d](https://github.com/viamin/paid/commit/3f4f25d08079776943d32343b990f98e247dcab8))
* **reviews:** author-gate the codex trigger-comment marker match ([86e20f0](https://github.com/viamin/paid/commit/86e20f091553dd3235d1c4fc0ac23f2e119ee264))
* **reviews:** block auto-merge until blocking review signals are complete ([b63d192](https://github.com/viamin/paid/commit/b63d1921ed50847638b2f72387ae4ad88e9eb338)), closes [#824](https://github.com/viamin/paid/issues/824)
* **reviews:** drop unnecessary safe-navigation and add defensive .to_h ([a5d2175](https://github.com/viamin/paid/commit/a5d2175a36b7535d10c7d804de1d3fe0439bd569))
* **reviews:** gate RequestReviewActivity arg-shape change behind workflow patch ([015eea9](https://github.com/viamin/paid/commit/015eea94c6daefaa7bcab8a43d4aa3814ff89c98))
* **reviews:** honor global review toggle in review_bot_request_login ([e339c01](https://github.com/viamin/paid/commit/e339c01e7d452736285dc8437db68147ce31a699))
* **reviews:** permit codex review settings in project updates ([8234026](https://github.com/viamin/paid/commit/8234026009c9fdfe171e616abb86f2e6d6b45080))
* **reviews:** scope review bot detection to enabled methods; use trigger login for review requests ([97286a6](https://github.com/viamin/paid/commit/97286a6ccf7fb4aceacb11309baa34adfb5b123f))
* **reviews:** suppress bot-review pending trigger when no bot is configured ([67de979](https://github.com/viamin/paid/commit/67de9791a923b1ea7f552660eefc3a2518dda37b))
* **reviews:** treat comment-fetch failure as already-triggered ([140e5a0](https://github.com/viamin/paid/commit/140e5a052ce8b059653fffbf1d12d771e6a3f737))
* **reviews:** trigger codex reviews on draft PRs via [@codex](https://github.com/codex) review comment ([6106f31](https://github.com/viamin/paid/commit/6106f318707ee688c2a71861cbc4175d750e9214))
* **reviews:** trigger codex reviews on draft PRs via [@codex](https://github.com/codex) review comment ([aea859c](https://github.com/viamin/paid/commit/aea859cd552cffd5e2ce6299d55ac3b4018a83a2)), closes [#897](https://github.com/viamin/paid/issues/897)
* **reviews:** validate each blocking signal independently for stale review detection ([4304e0b](https://github.com/viamin/paid/commit/4304e0b4b0d74c4a82f9c3d27d394bb4f7a0227c))
* **scanner:** address PR review feedback for non-bot review gating ([368a3b1](https://github.com/viamin/paid/commit/368a3b150790dcf131f27cf6faec48d592921bbd))
* **scanner:** address remaining PR review feedback for non-bot review gating ([81eab7c](https://github.com/viamin/paid/commit/81eab7cbef4b8e3c6936c9f6f3f78653b76c4b9d))
* **scanner:** address remaining review feedback on paid_agent clean signal ([13259ff](https://github.com/viamin/paid/commit/13259fffed1f00880d54eb5406f8a933e694df2f))
* **scanner:** address review feedback for paid_agent review triggers ([3b11803](https://github.com/viamin/paid/commit/3b118034c33f72629af640c131e3c5e7cb1a5fd9))
* **scanner:** address review feedback on paid_agent clean signal detection ([5a0874d](https://github.com/viamin/paid/commit/5a0874deccdf2998bc2e34ef6dbe394c409055e9))
* **scanner:** block draft exit when paid_agent is the only review method ([c7a2b76](https://github.com/viamin/paid/commit/c7a2b763c64af917311815767ffa8946a4599897)), closes [#914](https://github.com/viamin/paid/issues/914)
* **scanner:** body-only reviews persist across auto-continue pushes ([47a19f3](https://github.com/viamin/paid/commit/47a19f305ad5b55a9145bf17574326e6945f5a78)), closes [#1015](https://github.com/viamin/paid/issues/1015)
* **scanner:** check review feedback before auto-merge in ready phase ([#924](https://github.com/viamin/paid/issues/924)) ([6bfaa68](https://github.com/viamin/paid/commit/6bfaa685d287b97d7b8769433a4dcb3be7218cb2)), closes [#917](https://github.com/viamin/paid/issues/917)
* **scanner:** coerce max_review_rounds to integer in paid_agent_max_review_rounds ([91b0df9](https://github.com/viamin/paid/commit/91b0df9249b15640ab348620342e00f328877b8a))
* **scanner:** correct test expectations for body-only paid_agent reviews ([aaaa4d7](https://github.com/viamin/paid/commit/aaaa4d78297a208ec15e8b4cbab654e2b4993d4e))
* **scanner:** count submitted review comments in proxy warning ([f7f8165](https://github.com/viamin/paid/commit/f7f816576b8dd96afe701b36aa48db00184a4f01))
* **scanner:** detect codex clean signal posted as issue comment ([0ea7ea7](https://github.com/viamin/paid/commit/0ea7ea7618d953be00c61edc3dbad20ea6111d29)), closes [#910](https://github.com/viamin/paid/issues/910)
* **scanner:** detect merge conflicts when github_updated_at unchanged ([fd78c12](https://github.com/viamin/paid/commit/fd78c129b6904b81cb1fc5515bac6a153233450b)), closes [#1024](https://github.com/viamin/paid/issues/1024)
* **scanner:** enforce paid_agent max_review_rounds to prevent infinite review loops ([2ecd999](https://github.com/viamin/paid/commit/2ecd9991f0053be2fee141511cd013a1e3b2dc5a)), closes [#944](https://github.com/viamin/paid/issues/944)
* **scanner:** evaluate only latest review for paid_agent clean signal ([4cf7b1f](https://github.com/viamin/paid/commit/4cf7b1ff6c4336ef0aec6bb8715fc1cedf231256))
* **scanner:** gate draft exit and ready detection on manual and ci_action review methods ([cd7fc4d](https://github.com/viamin/paid/commit/cd7fc4d06f1dc3e55ca4a806fab73f4703acb228)), closes [#919](https://github.com/viamin/paid/issues/919)
* **scanner:** gate paid_agent round-limit enforcement on global review toggle ([8927e26](https://github.com/viamin/paid/commit/8927e262ddc51abd78ab25cc53b5fff435aafea7)), closes [#944](https://github.com/viamin/paid/issues/944)
* **scanner:** include codex body-only bots in escalation check ([0df84e4](https://github.com/viamin/paid/commit/0df84e44b2c08aa6ea7dad55da127264d04fc96a))
* **scanner:** include goal column in active-run uniqueness indexes ([b9f9426](https://github.com/viamin/paid/commit/b9f9426302d9cdf6fd0146a9b59527b59994a0ad))
* **scanner:** include paid_agent in BODY_ONLY_REVIEW_BOT_LOGINS ([6c48de0](https://github.com/viamin/paid/commit/6c48de0a299e6769cf1454ae5906fcd735f4b0f8)), closes [#1004](https://github.com/viamin/paid/issues/1004)
* **scanner:** prevent premature escalation when thread data is unavailable ([d42f00b](https://github.com/viamin/paid/commit/d42f00b36b4d9a887798eadc4e2fae10b535091c))
* **scanner:** prevent stale bot reviews from interfering with paid_agent-only config ([#916](https://github.com/viamin/paid/issues/916)) ([#925](https://github.com/viamin/paid/issues/925)) ([0e411b2](https://github.com/viamin/paid/commit/0e411b2feb83001a53fd416585fc2964f1aba481))
* **scanner:** resolve main merge and honor clean terminal paid_agent reviews ([6034dbf](https://github.com/viamin/paid/commit/6034dbf8b8ef786902ae8cf460f4c786fe86d85c))
* **scanner:** respect global review_enabled before queuing paid_agent reviews ([34077a1](https://github.com/viamin/paid/commit/34077a1580924ea38a2e5f3aa6480b8ad50b0665))
* **scanner:** restore completed state for review-goal failures instead of failed ([43a1865](https://github.com/viamin/paid/commit/43a186559cf4c63bee570212e2aeb88e72451314)), closes [#1005](https://github.com/viamin/paid/issues/1005)
* **scanner:** restrict clean-comment bypass to enabled review bots ([9cad023](https://github.com/viamin/paid/commit/9cad023a8f44c178007bd0ddead30682bff1df87))
* **scanner:** scope active_run_exists? to create_pr goal so review runs don't block scanning ([5a5f08d](https://github.com/viamin/paid/commit/5a5f08de9339ba609713b420125fd643672a307f))
* **scanner:** scope merge-conflict rescan to conflict detection only ([519f4fe](https://github.com/viamin/paid/commit/519f4fe5f99db4b71d027bf592d4f4119191021c))
* **schema:** remove phantom review_goal_retry_count column ([7821bb1](https://github.com/viamin/paid/commit/7821bb13f6972a143c4be1f748589398b223cc3f))
* **setup:** launch bin/dev with --detach so it survives terminal hangup ([bc525e3](https://github.com/viamin/paid/commit/bc525e3843ff0dbecc74af1d51c7be2add4a66c1))
* **specs:** fix prompt scope test ordering failure and reduce test noise ([b060fcd](https://github.com/viamin/paid/commit/b060fcdf9df9dc830f8d73930913516ad45f92bf))
* **specs:** update STATUSES constant spec to include no_output ([2bb070f](https://github.com/viamin/paid/commit/2bb070f2948fff5e15e34af522b8f11a05c86d55))
* **test:** require ostruct in mark_escalated_activity_spec for Ruby 3.4 compatibility ([a4e23e0](https://github.com/viamin/paid/commit/a4e23e0a429e590eb5a6089d284fe209151efe21))
* **test:** tolerate missing built assets in request specs ([215875d](https://github.com/viamin/paid/commit/215875daf9b0d9159bdfce66aa98d6967fbd4220))
* **ui:** add nil-safety guards to cost/token zero-checks ([1571a4b](https://github.com/viamin/paid/commit/1571a4b08c586b29dcfe6b0dcea96524ca7b0c05))
* **ui:** block restart on inactive projects ([df1f41f](https://github.com/viamin/paid/commit/df1f41fb11e45d9cb64d278408619866f3c55f42))
* **ui:** gate restart button on update policy ([8c63b95](https://github.com/viamin/paid/commit/8c63b95d13d7128fea8839b7e7f03050edfbeb07))
* **ui:** hide cost and token usage displays when values are zero ([733d007](https://github.com/viamin/paid/commit/733d0078f7cc4c5c715104af182d53087f16b8fb)), closes [#960](https://github.com/viamin/paid/issues/960)
* **ui:** prevent dangling separator when cost is zero but tokens exist ([81c2b44](https://github.com/viamin/paid/commit/81c2b4403d03c5e82e9a734fd6ab77a06e8998c6))
* **ui:** remove max duration/timeout display from duration columns ([1302def](https://github.com/viamin/paid/commit/1302def18d059848c311aab2077a1a45213d1026)), closes [#959](https://github.com/viamin/paid/issues/959)
* **workflow-status:** address PR review feedback for real-time status sync ([67dd103](https://github.com/viamin/paid/commit/67dd103554c4d7f6fc177f1273b632a0358f9d6e))
* **workflow-status:** include restart button in Turbo Stream broadcasts ([44c8bc7](https://github.com/viamin/paid/commit/44c8bc764ebde7d93923ea9d557a7f20232303bb))
* **workflow-status:** merge main, address review feedback ([96aebf8](https://github.com/viamin/paid/commit/96aebf821d82b719bfbec681be04769f173d8787))
* **workflow-status:** prevent started_at/restart_reason/error_message from being overwritten on poll cycles ([53cfc2d](https://github.com/viamin/paid/commit/53cfc2db35af1b7d972b80c0734ed1edd9a777da))
* **workflow:** add context to best_effort logging and wrap structured log ([36b16fc](https://github.com/viamin/paid/commit/36b16fca36db5356c4bca6a13b74f1a23f5f586a))
* **workflow:** address PR review feedback for CreatePullRequestActivity ([b1430ed](https://github.com/viamin/paid/commit/b1430ed03bead5106d8a775e552da159e78362c9))
* **workflow:** address review feedback for OrphanBranchReaperJob ([ce807ea](https://github.com/viamin/paid/commit/ce807ea8b55421edd4dcea43379b1362311a015d))
* **workflow:** make CreatePullRequestActivity idempotent ([6138651](https://github.com/viamin/paid/commit/61386515a5864f70cc3fce24c0e61cf7c7599602)), closes [#964](https://github.com/viamin/paid/issues/964)
* **workflow:** rescue lookup errors in find_existing_pr ([bd76420](https://github.com/viamin/paid/commit/bd764203797ddc701f691064da073e7a44fbd7dd))


### Performance Improvements

* **agent-runs:** constrain sibling issue query to referenced candidate numbers ([1270872](https://github.com/viamin/paid/commit/1270872e5290df71ef3cde067d7dce50232cf251))
* **agent-runs:** replace O(issues × summary) regex scan with single-pass extraction ([0116124](https://github.com/viamin/paid/commit/01161247d0c168d8e10b2be19c8e3031cac83828))
* **github-sync:** add proactive rate limit checks to polling activities ([c759155](https://github.com/viamin/paid/commit/c7591556a06a019f3777a346edd3fcaa1bd9121d)), closes [#868](https://github.com/viamin/paid/issues/868)
* **github-sync:** defer rate-limit check until PRs need scanning ([7a63c89](https://github.com/viamin/paid/commit/7a63c89842b2658566bb5f69c9f6a7b107e2da1c))
* **github-sync:** use incremental issue fetching with since parameter ([5576f87](https://github.com/viamin/paid/commit/5576f87ada97468c6a4e0f7a5c061535ac920732)), closes [#869](https://github.com/viamin/paid/issues/869)
* **poll-workflow:** add per-project rate limit budget coordination across activities ([9aab304](https://github.com/viamin/paid/commit/9aab3043434bbd76e8920dd9fe8bded52ad937bc)), closes [#872](https://github.com/viamin/paid/issues/872)
* **pr-scanner:** accept unresolved_threads kwarg in detect_ready_triggers ([#890](https://github.com/viamin/paid/issues/890)) ([41edaf3](https://github.com/viamin/paid/commit/41edaf3aeebab418e7c27127aeed733fad8f615f)), closes [#866](https://github.com/viamin/paid/issues/866)
* **pr-scanner:** skip unchanged PRs in ScanPaidPrsActivity ([fc008da](https://github.com/viamin/paid/commit/fc008dabf6c8721fcffe222fd873258088bba772)), closes [#867](https://github.com/viamin/paid/issues/867)
* **pr-scanner:** use recent_issue_comments instead of auto-paginated issue_comments ([95a9c5a](https://github.com/viamin/paid/commit/95a9c5a3fa8f42da63a8932a269764ed36a6c0a5)), closes [#870](https://github.com/viamin/paid/issues/870)
* **quality-metrics:** batch reaction fetching in CollectReviewReactionFeedback ([a38b178](https://github.com/viamin/paid/commit/a38b178f040a84c118d1c042e6c9cb2b09893c0c)), closes [#871](https://github.com/viamin/paid/issues/871)

## [0.19.0](https://github.com/viamin/paid/compare/v0.18.0...v0.19.0) (2026-04-11)


### Features

* **projects:** add manual stale run cleanup ([e482e7b](https://github.com/viamin/paid/commit/e482e7b9c095a845264e5fba28ef4212e33e6201))
* **providers:** support default providers by run type ([5df778a](https://github.com/viamin/paid/commit/5df778aa934176dd7010d71b90c543e683b216fd))


### Bug Fixes

* add missing reviewer_login field to manual review settings form ([5d04465](https://github.com/viamin/paid/commit/5d04465d34adb241a3585d0e5e81afb06b5e5965))
* add missing reviewer_login field to manual review settings form ([755976e](https://github.com/viamin/paid/commit/755976e6a63333a713f03f5710aed1a6d80226f8))
* **agent-runs:** clear container_id before Docker cleanup and lazy-evaluate stale count ([b9a8ba5](https://github.com/viamin/paid/commit/b9a8ba53c7de8cd8557cc12a1b80bfc90283f64b))
* **agent-runs:** include stale pending manual cleanup ([2ed8684](https://github.com/viamin/paid/commit/2ed86846e7a5ac4d843190e2f38946233d309ced))
* **agent-runs:** sync provider default with selected goal ([0e8ea34](https://github.com/viamin/paid/commit/0e8ea34ec36120fadfe13c7f52af2630f41dc819))
* **devcontainer:** enable init for zombie reaping ([0cc8d62](https://github.com/viamin/paid/commit/0cc8d62c4964b4f9e6a39d0e3867ea827ce2729e))
* permit reviewer_login in manual review strong params ([f83e17f](https://github.com/viamin/paid/commit/f83e17fc4cf126c2abad6d61cf1d75f6727663e1))
* **providers:** preserve goal defaults on invalid params ([99ee33d](https://github.com/viamin/paid/commit/99ee33d8b11627fe96f2ecd6f72c6c5967d9f4c6))
* **scanner:** block draft exit when paid_agent is the only review method ([429fe99](https://github.com/viamin/paid/commit/429fe990289179029ef97331ba18f3ea67a04dc6)), closes [#914](https://github.com/viamin/paid/issues/914)
* **scanner:** body-only reviews persist across auto-continue pushes ([e56c502](https://github.com/viamin/paid/commit/e56c5021abdc98d680418f071aec048ae00b85ab)), closes [#1015](https://github.com/viamin/paid/issues/1015)
* **scanner:** detect merge conflicts when github_updated_at unchanged ([2e63bb0](https://github.com/viamin/paid/commit/2e63bb06db1ee8cca28027c06981b70a77d0a3f5)), closes [#1024](https://github.com/viamin/paid/issues/1024)
* **scanner:** scope merge-conflict rescan to conflict detection only ([8fe001c](https://github.com/viamin/paid/commit/8fe001ce57cf11bcb234e8b8e2b72ffcc5bb89a0))
* **test:** tolerate missing built assets in request specs ([b9f1457](https://github.com/viamin/paid/commit/b9f145769e4ed4e0d58a170856c93d4620324461))

## [0.18.0](https://github.com/viamin/paid/compare/v0.17.0...v0.18.0) (2026-04-11)


### Features

* **agent-runs:** add diff-overlap check for summary scope validation ([d6e16bb](https://github.com/viamin/paid/commit/d6e16bbbab4a5f4afe44fa3f67dc7fcd3505365d))
* **dashboard:** rename Agent column to Goal in active runs table ([c1547f2](https://github.com/viamin/paid/commit/c1547f254f9db2ba3c4ebbefed481397984a3c44)), closes [#987](https://github.com/viamin/paid/issues/987)
* **scanner:** define post-escalation behavior after max_review_rounds ([#1006](https://github.com/viamin/paid/issues/1006)) ([341d671](https://github.com/viamin/paid/commit/341d671ef2b326e9fcf7ec0095195e84c5d7a5fe))


### Bug Fixes

* **credentials:** add paid-code-reviewer github app private key ([efbc545](https://github.com/viamin/paid/commit/efbc5456c5d2bd887aa33eeed70d10d56b59d530))
* **credentials:** add paid-code-reviewer github app private key ([f78930d](https://github.com/viamin/paid/commit/f78930dfdd460ed94999fa6fd62e9ee47d26cd65))
* **github-sync:** merge main, remove committed yarn cache artifacts ([7b9b6ee](https://github.com/viamin/paid/commit/7b9b6eeeec0803bcc0f828558f7d8372005209df))
* **github-sync:** merge main, resolve conflict in scan_paid_prs_activity.rb ([5419698](https://github.com/viamin/paid/commit/5419698f2387d459ea32241f8ebd8ce992ab3094))
* **knowledge:** handle content_hash collisions across different scope_paths ([ea8ff23](https://github.com/viamin/paid/commit/ea8ff235b1f480a27e304e2b83c4ca3719c90763)), closes [#982](https://github.com/viamin/paid/issues/982)
* **knowledge:** install gems before routes collection in container ([837265e](https://github.com/viamin/paid/commit/837265ec163b4ea1192bf7ba24e19db22622b29a)), closes [#983](https://github.com/viamin/paid/issues/983)
* **knowledge:** restore network isolation for collector containers ([07091fd](https://github.com/viamin/paid/commit/07091fdbe3db3908c6d4da887192e057e1eb49e4))
* **notifications:** add retry limit to RecordNotUnique rescue and expand Resolve specs ([92fa994](https://github.com/viamin/paid/commit/92fa994d4564993c827ee56feef83e12acb1faa8))
* **notifications:** clear read_at on re-publish so escalated notifications appear as unread ([8434942](https://github.com/viamin/paid/commit/8434942b7587ed997a14fa6bae90dfcc3a7c558f))
* **notifications:** compute broadcast counts server-side and add NULL-safe dedup index ([b33082c](https://github.com/viamin/paid/commit/b33082c953cf36c876f09781e924737014bef21f))
* **notifications:** handle race condition in Publish and add on_delete nullify for user FK ([a681210](https://github.com/viamin/paid/commit/a681210710f3293a4fa5b9c645c9deb7216d2478))
* **pr-review:** count only successful draft followups ([74c00a7](https://github.com/viamin/paid/commit/74c00a7247e95ef5df630fe03c800d931e528a87))
* remove .yarn-cache-v2/ build artifacts from repository ([13487c6](https://github.com/viamin/paid/commit/13487c6a90bee34d60b14be0b12bca85f10c5aaf))
* **reviews:** align manual_review_complete? and blocking_approval_timestamps with configured reviewer ([247c525](https://github.com/viamin/paid/commit/247c525df34f35f46906583d48047204e2bf9e4f))
* **scanner:** address review feedback for paid_agent review triggers ([191fe28](https://github.com/viamin/paid/commit/191fe28378bd1f5ceaf2dcc248013e465dcfdd5e))
* **scanner:** correct test expectations for body-only paid_agent reviews ([6c3d973](https://github.com/viamin/paid/commit/6c3d973fab38e4de133f6ec0b300887a1c31e686))
* **scanner:** include paid_agent in BODY_ONLY_REVIEW_BOT_LOGINS ([b697afd](https://github.com/viamin/paid/commit/b697afddf17dddaa6b4bbf390d2432427eb1e49e)), closes [#1004](https://github.com/viamin/paid/issues/1004)
* **scanner:** restore completed state for review-goal failures instead of failed ([2724176](https://github.com/viamin/paid/commit/272417696f7737793819d1690be2654b1611a9b9)), closes [#1005](https://github.com/viamin/paid/issues/1005)
* **workflow-status:** include restart button in Turbo Stream broadcasts ([950c76d](https://github.com/viamin/paid/commit/950c76d51c3d119d768835afa782076cee486d05))
* **workflow-status:** merge main, address review feedback ([2216460](https://github.com/viamin/paid/commit/22164600564b68a1a0d7c81f8998baed2096f900))

## [0.17.0](https://github.com/viamin/paid/compare/v0.16.0...v0.17.0) (2026-04-11)


### Features

* **agent-runs:** add "no_output" status for unproductive create_pr runs ([bcb1b8c](https://github.com/viamin/paid/commit/bcb1b8c78bd74ba830ad7282f3c6d05e30320b0f))
* **agent-runs:** add no_output status for unproductive create_pr runs ([1e355b5](https://github.com/viamin/paid/commit/1e355b540c1799c33e9735f95c61a4afaff06c6b))
* **agent-runs:** optimize queue priority SQL with LATERAL join and P1/P2/P3 labels ([#933](https://github.com/viamin/paid/issues/933)) ([93bf90e](https://github.com/viamin/paid/commit/93bf90e163625cca2538bd1aaeaa7eaf98ccb423))
* **agent-runs:** replace PR dropdown with multi-select table for review goal ([6356c0b](https://github.com/viamin/paid/commit/6356c0be800a6e724dd5ca733bdf286fa22d0c2d)), closes [#957](https://github.com/viamin/paid/issues/957)
* **projects:** add review type indicator badges to projects index ([2813adb](https://github.com/viamin/paid/commit/2813adbc9194cb49d596458cc8c77af88107b32e)), closes [#930](https://github.com/viamin/paid/issues/930)
* **projects:** add UI fields for configuring priority label names ([#923](https://github.com/viamin/paid/issues/923)) ([6ab1488](https://github.com/viamin/paid/commit/6ab1488e02aab80aa673778c083e909e2b5f6674))
* **projects:** change default execution timeout from 1800s to 3600s ([4354c1c](https://github.com/viamin/paid/commit/4354c1ce1dce18db49fc9880affcde1fe7e9ed80))
* **projects:** change default execution timeout from 1800s to 3600s ([#855](https://github.com/viamin/paid/issues/855)) ([4e8cff9](https://github.com/viamin/paid/commit/4e8cff9ab05e160696e8c7c0e0254e2a359d12ca))
* **projects:** increase default issue/PR count to 50 with user-configurable setting ([5f60c72](https://github.com/viamin/paid/commit/5f60c728dc0015599ff84cc59d6ae3294bd71912)), closes [#962](https://github.com/viamin/paid/issues/962)
* **prompts:** migrate all agent prompts into the prompts table ([8c8577a](https://github.com/viamin/paid/commit/8c8577a0099c54e56395dfd8ada492d5307f9650))
* **prompts:** migrate all agent prompts into the prompts table ([538a90a](https://github.com/viamin/paid/commit/538a90af8890e485a2d9599d21f30253a6baca6f))
* **prompts:** migrate goal-augmentation prompts and ban praise-only PR review comments ([acfa354](https://github.com/viamin/paid/commit/acfa35497116cfcd9237ede0026d91a2872d5491))
* **queue:** user-defined priority labels for issues and PRs ([#838](https://github.com/viamin/paid/issues/838)) ([cd548dc](https://github.com/viamin/paid/commit/cd548dc18668318c9d136de1293cbff4500bc8cb))
* **queue:** user-defined priority labels for issues and PRs ([#838](https://github.com/viamin/paid/issues/838)) ([e800879](https://github.com/viamin/paid/commit/e8008797c3388c8a87564330ca46ad2982b18d07))
* **scanner:** add clean signal detection for paid_agent reviews ([#918](https://github.com/viamin/paid/issues/918)) ([323d7d4](https://github.com/viamin/paid/commit/323d7d4cadcf4ad10ba48695d7f3ee32535d23fa))
* **settings:** add database CHECK constraints for display limit bounds ([6014410](https://github.com/viamin/paid/commit/60144107e6483f765a8362ed30515fa8bde5e65f))
* **ui:** add restart button for crashed poll workflows ([98600c3](https://github.com/viamin/paid/commit/98600c35ec1d67a32e7060e8f09733c05b9d17f4))
* **ui:** add restart button for crashed poll workflows ([7d6f84f](https://github.com/viamin/paid/commit/7d6f84f0ad5138a88935c41986d758fee66f9448)), closes [#899](https://github.com/viamin/paid/issues/899)


### Bug Fixes

* 864: skip unchanged issues when fetching comments ([#894](https://github.com/viamin/paid/issues/894)) ([afa8cc7](https://github.com/viamin/paid/commit/afa8cc735c9de9d1cb7b43abc4f703963f9662c9))
* 865: fix(github-client): add retry middleware to GraphQL connection ([#889](https://github.com/viamin/paid/issues/889)) ([f17cfe2](https://github.com/viamin/paid/commit/f17cfe280f48e044b3cee76818c7a68e87b6e4bf))
* 873: perf(quality-metrics): reduce DelayedHumanFeedbackCollectionJob sweep scope ([#881](https://github.com/viamin/paid/issues/881)) ([996df30](https://github.com/viamin/paid/commit/996df305f2fecfa1cd32395e2b416b1b92f45c1d))
* 874: feat(models): add tier metadata and per-provider tier configuration ([#880](https://github.com/viamin/paid/issues/880)) ([ceadca6](https://github.com/viamin/paid/commit/ceadca682ec14b97af152c9fb6b52760637e0706))
* 895: Draft review follow-up runs retry indefinitely when timing out silently ([#896](https://github.com/viamin/paid/issues/896)) ([d0402f4](https://github.com/viamin/paid/commit/d0402f4292fcb272ce76bfc82a79281039063810))
* 906: PR body rewriter-nil fallback dumps raw agent stdout instead of a templated description ([#907](https://github.com/viamin/paid/issues/907)) ([8b5d83e](https://github.com/viamin/paid/commit/8b5d83e3a351fd0135a1f3e78a8cad87ca6deeda))
* **agent-runs:** add HTTP 429/too many requests to timeout rate-limit patterns ([d560e80](https://github.com/viamin/paid/commit/d560e808866dc867205c417a682add8a7ad471b9))
* **agent-runs:** address final PR review feedback for clarity and test coverage ([c418f93](https://github.com/viamin/paid/commit/c418f937859f5e05beae9fc1ffe0ccbc3cb62605))
* **agent-runs:** address PR review feedback for input validation and code clarity ([0e7baf0](https://github.com/viamin/paid/commit/0e7baf06731396ce6ce2546615f69fd7d95fe530))
* **agent-runs:** address PR review feedback for multi-select table ([0749659](https://github.com/viamin/paid/commit/0749659082bf8ded902221a7813a71bece5d9660))
* **agent-runs:** address PR review feedback for server-side validation and code quality ([49a0b64](https://github.com/viamin/paid/commit/49a0b64517cf126a3906b8216dde87b3df51e9df))
* **agent-runs:** address remaining PR review feedback for robustness and UX ([981532f](https://github.com/viamin/paid/commit/981532f9f09c03628535f8c564f2579ccd836109))
* **agent-runs:** address remaining review comments on timeout reclassification ([401db1e](https://github.com/viamin/paid/commit/401db1e704e6939633657732a2bd4e0dcaf84f83))
* **agent-runs:** address review feedback on timeout reclassification ([4d6e8ee](https://github.com/viamin/paid/commit/4d6e8ee55d6d3b8888ea4cd3552d8efb64f9d836))
* **agent-runs:** aggregate LATERAL join labels and use LEFT JOIN for projects ([0646393](https://github.com/viamin/paid/commit/0646393621890cd3cadec60c91db35321685fc1a))
* **agent-runs:** bound timeout log scan and tighten phrase matching ([fd60b67](https://github.com/viamin/paid/commit/fd60b67e17994adebdcd49bd5ae7715224d341f5))
* **agent-runs:** classify quota timeouts as rate limits ([18ce33f](https://github.com/viamin/paid/commit/18ce33f216f22e43062f99f6dc3afa79a43b5bd6))
* **agent-runs:** eager-load PRs and pass locals to shared partial ([3dd9627](https://github.com/viamin/paid/commit/3dd962712a1b9f10d637892f7ded4fb825b0b3c5))
* **agent-runs:** PR review table invisible on trigger form ([a8d7f93](https://github.com/viamin/paid/commit/a8d7f9303b2a677b48a57d357ad1a4bd301d5afc))
* **agent-runs:** PR review table invisible when selecting PR Code Review goal ([d78cfb2](https://github.com/viamin/paid/commit/d78cfb257946be169cce10991639e2a5da783be0))
* **agent-runs:** restore iterations guard for non-no_output statuses in draft breaker ([bdf2526](https://github.com/viamin/paid/commit/bdf2526ea078b888d3e0a708e971d71c556b52b0))
* **agent-runs:** revert whitespace-only db/schema.rb changes per review ([de17af2](https://github.com/viamin/paid/commit/de17af234829b9ee72b72b436a396631ed25aae1))
* **auto-merge:** address remaining review feedback ([6ea8b14](https://github.com/viamin/paid/commit/6ea8b144db660727ce0236f7d0482bd1f7a49af9))
* **auto-merge:** address review feedback on file-diff heuristic ([35951f1](https://github.com/viamin/paid/commit/35951f14464b3015d244c7f25ddbb57aea260bb0))
* **auto-merge:** address review feedback on HEAD commit verification ([7094488](https://github.com/viamin/paid/commit/70944886794d472e4e5c6e987698fa91aef631e2))
* **auto-merge:** address second-round review feedback on HEAD commit verification ([32785e5](https://github.com/viamin/paid/commit/32785e5e528923b383e8f0f95a4f5a8c16e57f8f))
* **auto-merge:** check affected files when clearing body-only review feedback ([c31655b](https://github.com/viamin/paid/commit/c31655bff6fbf62b751f544cb0ddc5e0dc013b6c)), closes [#935](https://github.com/viamin/paid/issues/935)
* **auto-merge:** require clean re-review on HEAD commit for body-only bot clearance ([e8dc9d9](https://github.com/viamin/paid/commit/e8dc9d9cc587706e70dfe66fffcf1a1b901840ff)), closes [#934](https://github.com/viamin/paid/issues/934)
* **dev-cleanup:** also short-circuit InfiniteLoopError + add predicate specs ([007b462](https://github.com/viamin/paid/commit/007b462e322725860833ae7d09cda098a5dfe314))
* **dev-cleanup:** clarify reload contract in cleanup guard comment ([8eb7c29](https://github.com/viamin/paid/commit/8eb7c29bb64c21cf794474a143c276953c26c0c3))
* **dev-cleanup:** don't trip provider circuit breaker when cleanup kills runs ([071e7af](https://github.com/viamin/paid/commit/071e7af1087ac60adaea2dbf5b7f46209494956e))
* **dev-cleanup:** don't trip provider circuit breaker when cleanup kills runs ([9894545](https://github.com/viamin/paid/commit/989454547fdc132eb12de904d39f4abdbdf101e9)), closes [#931](https://github.com/viamin/paid/issues/931)
* **dev-cleanup:** skip ProcessRunQueueJob dispatch on cleanup-cancelled timeouts ([99f482f](https://github.com/viamin/paid/commit/99f482fd63feebb655715c2bff7651e8ae056f0f))
* **dev:** add --detach mode and clean stale overmind tmp dirs ([0692701](https://github.com/viamin/paid/commit/06927015e71f079f053b0eb546f12e7a722cbbf8))
* **dev:** add --detach mode and clean stale overmind tmp dirs ([ce9775b](https://github.com/viamin/paid/commit/ce9775b242c9a11b9d8fc794d2489ca65df6f00e))
* **dev:** address PR review feedback for detach mode ([d9ad7e2](https://github.com/viamin/paid/commit/d9ad7e2e322f8f15a0e1b79ac2e157e4bb7ef9ab))
* **dev:** clarify detached PID is setsid wrapper and document bin/setup UX change ([35ba7ba](https://github.com/viamin/paid/commit/35ba7bae649df05f0744bf93a3d1faec8d50e8d3))
* **github-client:** recent_issue_comments must follow Link: last for newest comments ([27e1f9b](https://github.com/viamin/paid/commit/27e1f9bb5b991b5f830db6adc4cc13248df89df9))
* **knowledge:** handle EOF in archive_in_stream chunker ([032f831](https://github.com/viamin/paid/commit/032f831b5616ac8e0d5e606c610c34d5a338c8a2))
* **knowledge:** handle EOF in archive_in_stream chunker ([1d4fcea](https://github.com/viamin/paid/commit/1d4fcea5c21aa550e5df8a47d6c1d022395b46ff))
* **poll-workflow:** preserve old non-critical path when patch guard is absent ([60492fd](https://github.com/viamin/paid/commit/60492fd4c9d2978d568a70472047d2f5d0ae57c4))
* **pr-review:** detect codex body-only reviews as unaddressed feedback ([682747f](https://github.com/viamin/paid/commit/682747f1aa2abd53286fd4841dd0156f8c904f56))
* **pr-review:** detect codex body-only reviews as unaddressed feedback ([754f5a1](https://github.com/viamin/paid/commit/754f5a1bec0f125a6a21f8c58821bda84fee7f6e)), closes [#901](https://github.com/viamin/paid/issues/901) [#807](https://github.com/viamin/paid/issues/807)
* **pr-review:** detect codex clean signal posted as an issue comment ([8097ce3](https://github.com/viamin/paid/commit/8097ce31e6f22bc1a5441468c2d2a65eedc04e3d))
* **pr-review:** detect codex clean signal posted as an issue comment ([abc7d3e](https://github.com/viamin/paid/commit/abc7d3eb437b263e6d04b566e30b5982bc49735a))
* **pr-review:** restrict codex clean-comment override to body-only-only configs ([d7bacc4](https://github.com/viamin/paid/commit/d7bacc44ffc0f66962395cac9f3cd02c5c6b1b2d))
* **pr-scanner:** address review feedback on recent_issue_comments ([47474b0](https://github.com/viamin/paid/commit/47474b020fbf82ec3219347a8b08a19e35fce634))
* **pr-scanner:** address review feedback on recent_issue_comments ([5b88143](https://github.com/viamin/paid/commit/5b88143db66527bb860193bdfa8fbb0cd07f1e87))
* **pr-scanner:** address review feedback on skip-unchanged-PRs ([e0f1d07](https://github.com/viamin/paid/commit/e0f1d07dc9c201922479978960aa519f8d403720))
* **pr-scanner:** address review feedback on skip-unchanged-PRs ([6957050](https://github.com/viamin/paid/commit/6957050fc5a5d8013617f87bc83ec8ff0a61bd45))
* **pr-scanner:** clean up schema.rb formatting noise from merge ([f0b7cff](https://github.com/viamin/paid/commit/f0b7cff36b71093ef463f60d2b6b4a277580ace7))
* **pr-scanner:** defer last_pr_scan_at stamp when triggers are emitted ([e768ac8](https://github.com/viamin/paid/commit/e768ac865a64d78e3a286543f6f3f1b0b9c3b82e))
* **pr-scanner:** emit actionable triggers on partial API failures in ready phase ([93c1158](https://github.com/viamin/paid/commit/93c1158b7bddbbb965773d34ed683bd8a9874dfe))
* **pr-scanner:** fall back to full pagination when cutoff exceeds recent page ([b179263](https://github.com/viamin/paid/commit/b179263c68d4979a8e2f3dfe2709fb42b4db144d))
* **pr-scanner:** fall back to full pagination when cutoff exceeds recent page ([d07a9d7](https://github.com/viamin/paid/commit/d07a9d749ddc8885ed9a5f053aec86ab0ed29ed1))
* **pr-scanner:** only update last_pr_scan_at after successful scan ([49bd17a](https://github.com/viamin/paid/commit/49bd17add7f5229a680f6c49a26effe704e5cbc9))
* **pr-scanner:** resolve merge conflicts with main ([a657c06](https://github.com/viamin/paid/commit/a657c06fddf2cc2bbc06adaea4ba7f7638b6d0a4))
* **pr-scanner:** scan full recent-comments page for conversation triggers ([12a583f](https://github.com/viamin/paid/commit/12a583fad542f670ecf9604338b51bb520f80e88)), closes [#870](https://github.com/viamin/paid/issues/870)
* **pr-scanner:** skip last_pr_scan_at stamp when ready/escalated API calls fail ([17d123c](https://github.com/viamin/paid/commit/17d123c4d35631df3e60a9229b93b18c55950df7))
* **pr-scanner:** stamp last_pr_scan_at after any completed scan and clean schema.rb ([1e2e9d0](https://github.com/viamin/paid/commit/1e2e9d0b8af9701bc5e37c2102e167e982bee0e1))
* **projects:** add startup validation and logging for review method badges ([9276d8a](https://github.com/viamin/paid/commit/9276d8a80aacad9cd4fee9a8ed8579f37e2cdc30))
* **projects:** address PR review feedback for priority label fields ([01a2860](https://github.com/viamin/paid/commit/01a2860f5069463b7b1c0038921105373d0053c0))
* **projects:** address PR review feedback for priority label fields ([23497bd](https://github.com/viamin/paid/commit/23497bdfc46eb30143269ac1b755e952ab560cae))
* **projects:** address review feedback on review method badges ([6181b91](https://github.com/viamin/paid/commit/6181b91f94705ebfc19295f9e4c9896dd90cc576))
* **projects:** drop unsafe container_timeout_seconds backfill and correct schema version ([b2649cd](https://github.com/viamin/paid/commit/b2649cd945316bd63aeb09dc9873144ed2fe030e))
* **projects:** permit inherit_priority_labels in strong params ([#838](https://github.com/viamin/paid/issues/838)) ([8d05e79](https://github.com/viamin/paid/commit/8d05e79c19acd35844c470d230e955981f23fbfc))
* **projects:** split guard clause and logging in review_method_badge ([6343ce0](https://github.com/viamin/paid/commit/6343ce0a1d64197c278caa09c1557be52155c361))
* **prompts:** address code review findings on extract fallback and DRY service sections ([c39f735](https://github.com/viamin/paid/commit/c39f735c5602f24584b02c6a738a9e0c01b17b57))
* **prompts:** address code review findings on prompts migration ([0d41516](https://github.com/viamin/paid/commit/0d4151645d0b04e6d16eb7f9850f4f1a0c15b313))
* **prompts:** address code review findings on prompts migration ([9eba6f2](https://github.com/viamin/paid/commit/9eba6f2aae66d3d6307da8d2d9454908b7cbe351))
* **prompts:** address second round of code review findings ([2f68f59](https://github.com/viamin/paid/commit/2f68f59ca60bafa31a061e06161b3f91fb2a0f96))
* **quality-metrics:** address review feedback on batch reaction fetching ([aff2bbc](https://github.com/viamin/paid/commit/aff2bbca25db70fc030233c8766f832790c17b35))
* **quality-metrics:** address review feedback on batch reaction fetching ([6b9f773](https://github.com/viamin/paid/commit/6b9f773f36f6dc69420622e35fa411c656c531a9))
* **quality-metrics:** log truncation warnings for paginated GraphQL connections ([062e5df](https://github.com/viamin/paid/commit/062e5df4e1787024a1b861eda1f94d3666348034))
* **quality-metrics:** raise GraphQL errors and paginate overflowing reactions ([4c57126](https://github.com/viamin/paid/commit/4c57126c99e4b205505549d22c1a730886fbcc05))
* **quality-metrics:** remove unused reviewComments field from GraphQL query ([bebc761](https://github.com/viamin/paid/commit/bebc7615ae35f5c91277ec58b686e49a4202afb9))
* **quality-metrics:** rename max_comments to max_threads and rescue per-comment fallback failures ([9a8bd19](https://github.com/viamin/paid/commit/9a8bd19353f2a25d90f6f8928cc5fda913955101))
* **quality:** address PR review feedback for webhook feedback lookup ([5d14796](https://github.com/viamin/paid/commit/5d14796b6cd4cbb371096369bfd544ae57a62971))
* **quality:** document intentional review-goal fallback scope and index gap ([f97628e](https://github.com/viamin/paid/commit/f97628e17d76f80bd0b4cc1b38bd9bfbad26ad7b))
* **quality:** find review-goal agent runs in webhook feedback lookup ([5f6711c](https://github.com/viamin/paid/commit/5f6711c829729903adeb0a978f99135973a4501b)), closes [#943](https://github.com/viamin/paid/issues/943)
* **queue:** address PR review feedback for priority labels ([#838](https://github.com/viamin/paid/issues/838)) ([7a05734](https://github.com/viamin/paid/commit/7a05734b93385ecee7ad56ba12db55d46167a36e))
* **queue:** address review feedback round 8 ([#838](https://github.com/viamin/paid/issues/838)) ([f2cffae](https://github.com/viamin/paid/commit/f2cffaedf55652905ffa9cabc5231195a8cf904f))
* **queue:** batch-load source PR rows + permit priority_labels ([#838](https://github.com/viamin/paid/issues/838)) ([eb5673b](https://github.com/viamin/paid/commit/eb5673be70d3bc172a22a6433467d530fedfcbae))
* **queue:** document SQL OR semantics + precise PR preload ([#838](https://github.com/viamin/paid/issues/838)) ([def7f9c](https://github.com/viamin/paid/commit/def7f9c16d1e6ba3f3059c70fca47c7952ef77b2))
* **queue:** index issues for queue SQL + decouple priority inheritance from auto-add ([#838](https://github.com/viamin/paid/issues/838)) ([9d09006](https://github.com/viamin/paid/commit/9d090066c75fece17d759852a0afd0d0fac26e32))
* **queue:** inherit priority labels in aggregated PR + recovery ([#838](https://github.com/viamin/paid/issues/838)) ([7ef53a2](https://github.com/viamin/paid/commit/7ef53a247f75ab789e865a314545b271266817be))
* **queue:** memoize tier lookup and treat null label values as unset ([#838](https://github.com/viamin/paid/issues/838)) ([ac473b9](https://github.com/viamin/paid/commit/ac473b9593316b02cfb247411cf2cf57205f9ef5))
* **queue:** preload priority-label sources on project dashboard ([#838](https://github.com/viamin/paid/issues/838)) ([12fdfb5](https://github.com/viamin/paid/commit/12fdfb52efbe04d99b4ebc8abdafad1d84ae563b))
* resolve merge conflicts with main for LATERAL join optimization ([bd99a28](https://github.com/viamin/paid/commit/bd99a28cac3372c13c3b233f9371b0c559c820af))
* **reviews:** author-gate the codex trigger-comment marker match ([c7f1139](https://github.com/viamin/paid/commit/c7f11392ea95b4afb8a021bb085b9d7e0e4d417b))
* **reviews:** gate RequestReviewActivity arg-shape change behind workflow patch ([887bde1](https://github.com/viamin/paid/commit/887bde1347b1c4a530c4bf74e4b866f75a783a0e))
* **reviews:** honor global review toggle in review_bot_request_login ([9311ff1](https://github.com/viamin/paid/commit/9311ff116bd8ccc86bda53ae37e3d0011e921d06))
* **reviews:** suppress bot-review pending trigger when no bot is configured ([e4285dd](https://github.com/viamin/paid/commit/e4285ddda324438ac9caa675c0230bfd87994ab4))
* **reviews:** treat comment-fetch failure as already-triggered ([dd8be24](https://github.com/viamin/paid/commit/dd8be24e79e9a84c2fe1babc37ccba1c741f377e))
* **reviews:** trigger codex reviews on draft PRs via [@codex](https://github.com/codex) review comment ([0abab8a](https://github.com/viamin/paid/commit/0abab8abc77a082c57a759213fdba584b1c7f86b))
* **reviews:** trigger codex reviews on draft PRs via [@codex](https://github.com/codex) review comment ([c10a03e](https://github.com/viamin/paid/commit/c10a03eb7de0439761e7d6a5a4dd59b1037f7832)), closes [#897](https://github.com/viamin/paid/issues/897)
* **scanner:** address PR review feedback for non-bot review gating ([1cca861](https://github.com/viamin/paid/commit/1cca8615f3c8acad96f93e6e2e8abb9ec9dec97e))
* **scanner:** address remaining PR review feedback for non-bot review gating ([e858b54](https://github.com/viamin/paid/commit/e858b54a6a00704ae6bd3bb8b1af3783646855f7))
* **scanner:** address remaining review feedback on paid_agent clean signal ([d472479](https://github.com/viamin/paid/commit/d4724790a225fa7a69759550bc2ec4cdd9975b5c))
* **scanner:** address review feedback on paid_agent clean signal detection ([4f1c8b5](https://github.com/viamin/paid/commit/4f1c8b50f8f580991edcf39dd466566c425b3efe))
* **scanner:** check review feedback before auto-merge in ready phase ([#924](https://github.com/viamin/paid/issues/924)) ([73e9b86](https://github.com/viamin/paid/commit/73e9b86afe7364b998111cd392c33f79424ea9f6)), closes [#917](https://github.com/viamin/paid/issues/917)
* **scanner:** detect codex clean signal posted as issue comment ([0db66e4](https://github.com/viamin/paid/commit/0db66e4d4ef7eb760d4328316b6afb6a5d20ae0c)), closes [#910](https://github.com/viamin/paid/issues/910)
* **scanner:** evaluate only latest review for paid_agent clean signal ([fdc05ed](https://github.com/viamin/paid/commit/fdc05ed33438872b923928d846c9fc7cdf2f15c1))
* **scanner:** gate draft exit and ready detection on manual and ci_action review methods ([32017e6](https://github.com/viamin/paid/commit/32017e6fa1be382af4b88626742a6a890a53eb9f)), closes [#919](https://github.com/viamin/paid/issues/919)
* **scanner:** prevent stale bot reviews from interfering with paid_agent-only config ([#916](https://github.com/viamin/paid/issues/916)) ([#925](https://github.com/viamin/paid/issues/925)) ([3f04c51](https://github.com/viamin/paid/commit/3f04c511570250f460177b3cc006b2d46a22cee5))
* **scanner:** restrict clean-comment bypass to enabled review bots ([54cd6de](https://github.com/viamin/paid/commit/54cd6de713dc0705e09537072056d4587668b1f7))
* **setup:** launch bin/dev with --detach so it survives terminal hangup ([c22f469](https://github.com/viamin/paid/commit/c22f4699492df9089a11ebb15185e09138aa3d74))
* **specs:** fix prompt scope test ordering failure and reduce test noise ([94b3ddd](https://github.com/viamin/paid/commit/94b3ddd4a34cf2c314f8584ba1ffb96a908fc7f5))
* **specs:** update STATUSES constant spec to include no_output ([cd4b676](https://github.com/viamin/paid/commit/cd4b676c7c66bb1e83a9915fd206806dbf005b67))
* **ui:** add nil-safety guards to cost/token zero-checks ([87c02f8](https://github.com/viamin/paid/commit/87c02f81b27f3ca2f0777dd49e8435929e8244e2))
* **ui:** block restart on inactive projects ([3974de9](https://github.com/viamin/paid/commit/3974de9d427feea78138c74cb21d0a35d5615c21))
* **ui:** gate restart button on update policy ([e93d777](https://github.com/viamin/paid/commit/e93d777933946b5aa7ebe91cc3eff5ae7a1fc6bb))
* **ui:** hide cost and token usage displays when values are zero ([101e4c7](https://github.com/viamin/paid/commit/101e4c72a10289450e0310291f8608a4beb14e85)), closes [#960](https://github.com/viamin/paid/issues/960)
* **ui:** prevent dangling separator when cost is zero but tokens exist ([02474cd](https://github.com/viamin/paid/commit/02474cd55fccfc78a1607a344aa044aec73a2e90))
* **ui:** remove max duration/timeout display from duration columns ([3c32673](https://github.com/viamin/paid/commit/3c3267310c3e1420c62ed2167c9c06eb4a1585d7)), closes [#959](https://github.com/viamin/paid/issues/959)
* **workflow:** add context to best_effort logging and wrap structured log ([d815cd4](https://github.com/viamin/paid/commit/d815cd4b9dd9b268545b99b624669344fd8d2908))
* **workflow:** address PR review feedback for CreatePullRequestActivity ([4fcadc4](https://github.com/viamin/paid/commit/4fcadc427d627a0ba2a9778b0c59643b2a5d9269))
* **workflow:** make CreatePullRequestActivity idempotent ([17c8370](https://github.com/viamin/paid/commit/17c8370df8a2344a971bd03594f29052b6ec775f)), closes [#964](https://github.com/viamin/paid/issues/964)
* **workflow:** rescue lookup errors in find_existing_pr ([c8e83cc](https://github.com/viamin/paid/commit/c8e83ccb62b37be32e1e6cdeb915a7774be83f83))


### Performance Improvements

* **poll-workflow:** add per-project rate limit budget coordination across activities ([71181ea](https://github.com/viamin/paid/commit/71181eaccaefbbf016269e4a5fcd9009aefd39b5)), closes [#872](https://github.com/viamin/paid/issues/872)
* **pr-scanner:** accept unresolved_threads kwarg in detect_ready_triggers ([#890](https://github.com/viamin/paid/issues/890)) ([cb4733d](https://github.com/viamin/paid/commit/cb4733d09e58d88cfc7e0de5dcdacccf269703db)), closes [#866](https://github.com/viamin/paid/issues/866)
* **pr-scanner:** skip unchanged PRs in ScanPaidPrsActivity ([d1f91dd](https://github.com/viamin/paid/commit/d1f91dd0b8b387f95df19257d3bbc05c1087994d)), closes [#867](https://github.com/viamin/paid/issues/867)
* **pr-scanner:** use recent_issue_comments instead of auto-paginated issue_comments ([b4586df](https://github.com/viamin/paid/commit/b4586df521182924cdb1053d30f9c4ad898525eb)), closes [#870](https://github.com/viamin/paid/issues/870)
* **quality-metrics:** batch reaction fetching in CollectReviewReactionFeedback ([6099b7e](https://github.com/viamin/paid/commit/6099b7ec6daf4b542eda6990e8d4f26f8def1efa)), closes [#871](https://github.com/viamin/paid/issues/871)

## [0.16.0](https://github.com/viamin/paid/compare/v0.15.0...v0.16.0) (2026-04-07)


### Features

* **projects:** show recently merged pull requests ([#774](https://github.com/viamin/paid/issues/774)) ([df585ff](https://github.com/viamin/paid/commit/df585ff129d85be93a6b90e8334227925571429d))
* **providers:** add z.ai to DIRECT_OUTBOUND_API_PROVIDERS ([1c844c1](https://github.com/viamin/paid/commit/1c844c170f613a3495ec6930b0f3fbd9e04ff078))
* **providers:** add z.ai to DIRECT_OUTBOUND_API_PROVIDERS ([9213c86](https://github.com/viamin/paid/commit/9213c863cf23cd36fe50839ca1fda904ae288c5e)), closes [#845](https://github.com/viamin/paid/issues/845)
* **providers:** multi-provider direct outbound for OpenCode and KiloCode ([#769](https://github.com/viamin/paid/issues/769)) ([925c800](https://github.com/viamin/paid/commit/925c800b7aa7deff56e3eddb454494cce586fe0f))
* **providers:** register z.ai in API_SERVICE_TYPES only ([8895586](https://github.com/viamin/paid/commit/8895586ed1892d0d9782ce28c717d35a1efcb18d))
* **providers:** register z.ai in API_SERVICE_TYPES only ([10cc193](https://github.com/viamin/paid/commit/10cc193fdfded5d1b40eff325cc8496b86aefd54))
* **reviews:** add OpenAI Codex as a configurable PR review method ([aa16856](https://github.com/viamin/paid/commit/aa16856e8e7b4710e43b025c07b77ce64b87b53d))
* **reviews:** add OpenAI Codex as a configurable PR review method ([336105a](https://github.com/viamin/paid/commit/336105ae939ac0db49b1fe9307ce42c51a4f07e4)), closes [#804](https://github.com/viamin/paid/issues/804)


### Bug Fixes

* 698: feat(orchestration): conflict detection and resolution for parallel agents ([#758](https://github.com/viamin/paid/issues/758)) ([e82990c](https://github.com/viamin/paid/commit/e82990cbdbc043b87267221d2e02c423cd717430))
* 701: feat(guardrails): add token usage limits per agent run ([#761](https://github.com/viamin/paid/issues/761)) ([8a2c631](https://github.com/viamin/paid/commit/8a2c631e7a63322215ac3c78deff9d14b843eed8))
* 704: feat(guardrails): implement anomaly detection for agent behavior ([#766](https://github.com/viamin/paid/issues/766)) ([270f983](https://github.com/viamin/paid/commit/270f983296137b40c6d59d044903490a23235d1d))
* 705: feat(guardrails): automatic pause and alert system for guardrail violations ([#768](https://github.com/viamin/paid/issues/768)) ([01b2e5d](https://github.com/viamin/paid/commit/01b2e5dfdcbb31d32ea1375fa9035efd11233557))
* 707: feat(evolution): random sampling of completed runs for prompt evaluation ([#773](https://github.com/viamin/paid/issues/773)) ([85c1322](https://github.com/viamin/paid/commit/85c13225432ee6a915f79c9fafa408025958f0dc))
* 708: feat(evolution): implement prompt mutation agent ([#772](https://github.com/viamin/paid/issues/772)) ([2b180ba](https://github.com/viamin/paid/commit/2b180ba886158b8136a10030dc843d11db7baa8a))
* 722: feat(performance): worker pool tuning and optimization ([#816](https://github.com/viamin/paid/issues/816)) ([e02c3e8](https://github.com/viamin/paid/commit/e02c3e8740cebae756c73a66a85160446779a403))
* add missing frozen_string_literal comment to output_sanitizer.rb ([6150103](https://github.com/viamin/paid/commit/6150103213020c0d04073d9f3dcb2447ba9d9967))
* **agent-runs:** address binary output review feedback ([f08d6aa](https://github.com/viamin/paid/commit/f08d6aa7e4ac9e5a97eb05d35640c9fca541db89))
* **agent-runs:** clarify automatic run provider refresh semantics ([67e0bfb](https://github.com/viamin/paid/commit/67e0bfb67e87a3902f6e8d009612488623225be7))
* **agent-runs:** document sanitizer nil fast path ([e13bf22](https://github.com/viamin/paid/commit/e13bf2225e250ab08539cf5ce08749fb9b671e34))
* **agent-runs:** harden output normalization ([f484728](https://github.com/viamin/paid/commit/f4847282363d3e5c008b6c294f8c2925c124e755))
* **agent-runs:** honor provider routing and primary selection ([31fed0b](https://github.com/viamin/paid/commit/31fed0b571c79daf8c5e29d3af9b924bba961df7))
* **agent-runs:** honor provider routing and primary selection ([2f84e07](https://github.com/viamin/paid/commit/2f84e071e5eb4a954d9c439c3f317e43a3bb7770))
* **agent-runs:** ignore echoed prompts in rate limit detection ([da14056](https://github.com/viamin/paid/commit/da1405665fb334d30dd8a5ab4de01d7a4a7f4e9f))
* **agent-runs:** ignore echoed prompts in rate limit detection ([e026a48](https://github.com/viamin/paid/commit/e026a480d1a64c446b56c694819e64c660e597b8))
* **agent-runs:** normalize binary agent output ([076a38e](https://github.com/viamin/paid/commit/076a38e1661bcceed772a89c791b21ea002df21b))
* **agent-runs:** normalize binary agent output ([cc996c3](https://github.com/viamin/paid/commit/cc996c31eec95b8772195f1ea1c1854357397ef5))
* **agent-runs:** normalize binary output fallback paths ([53f84d2](https://github.com/viamin/paid/commit/53f84d2fc39af262c4c662a3d037dbd7576f9456))
* **agent-runs:** normalize binary output fallback paths ([67351d4](https://github.com/viamin/paid/commit/67351d4023c04456062dc7181777595c851ec25b))
* **agent-runs:** preserve utf-8 output bytes ([c39244a](https://github.com/viamin/paid/commit/c39244a2e73016d4a5ace1c62b30143660d1e51e))
* **agent-runs:** refresh provider selection and require explicit provider models ([8f1d847](https://github.com/viamin/paid/commit/8f1d847d149438064d52e6690f51f1016e678558))
* **agent-runs:** refresh provider selection and require explicit provider models ([6d2d4c9](https://github.com/viamin/paid/commit/6d2d4c960ad1f434a5b695d1e1cdd24f2135a509))
* **agent-runs:** remove rails helper asset bootstrap ([167546b](https://github.com/viamin/paid/commit/167546b12489b86e6007ece386a52d3ce9164851))
* **agent-runs:** restore test setup safeguards ([bc020a7](https://github.com/viamin/paid/commit/bc020a7b8df7da38ae7c0592d557d08df0524955))
* **agent-runs:** unify poll-triggered scheduling behind queue ([#806](https://github.com/viamin/paid/issues/806)) ([5734eb3](https://github.com/viamin/paid/commit/5734eb30e1dcee0ba561d94d5b4e6219b9fb92a4))
* **devcontainer:** configure KiloCode auto-approval inside container only ([8b5f99d](https://github.com/viamin/paid/commit/8b5f99d35f2a04aae4371e98e19929ef48df4e02))
* **devcontainer:** configure KiloCode auto-approval inside container only ([8dcc906](https://github.com/viamin/paid/commit/8dcc906ade82e660f56b729ef37a5ae5c8ff7ad5)), closes [#861](https://github.com/viamin/paid/issues/861)
* **projects:** expose security automation settings ([#765](https://github.com/viamin/paid/issues/765)) ([caf147f](https://github.com/viamin/paid/commit/caf147f409a0762d16ec411d6a92744bab7eb09a))
* **providers:** align required model messaging and specs ([df79ae5](https://github.com/viamin/paid/commit/df79ae54c6b23e98f1bbe75bce3e7f4b29b50b2d))
* **providers:** repair Copilot CLI container integration ([#786](https://github.com/viamin/paid/issues/786)) ([960907c](https://github.com/viamin/paid/commit/960907c5c37905e43d6b58db29b128c105a0073d))
* **providers:** restore codex sandbox bypass for test agent ([6b4fb87](https://github.com/viamin/paid/commit/6b4fb87540e18b6ad294efc079877723ba5db21a))
* **providers:** restore codex sandbox bypass for test agent ([db5edc8](https://github.com/viamin/paid/commit/db5edc81d36d6aff39f285ae7456c423395ec1d8))
* **providers:** sync test agent status with rate limit results ([10f27bb](https://github.com/viamin/paid/commit/10f27bbc6329bb4de05bc7acfce14e560722d1d3))
* **providers:** sync test agent status with rate limit results ([7c8a640](https://github.com/viamin/paid/commit/7c8a640ce859f161e17b96bd5f08b14d4d374538))
* **reviews:** permit codex review settings in project updates ([0a1f1a4](https://github.com/viamin/paid/commit/0a1f1a453e36d2f8d45b6144f0181a3479c77cd2))
* **reviews:** scope review bot detection to enabled methods; use trigger login for review requests ([ce7e5e9](https://github.com/viamin/paid/commit/ce7e5e98a6b56793587204f75933943420b51743))

## [0.15.0](https://github.com/viamin/paid/compare/v0.14.2...v0.15.0) (2026-04-03)


### Features

* **guardrails:** add execution time limits for agent runs ([#703](https://github.com/viamin/paid/issues/703)) ([#762](https://github.com/viamin/paid/issues/762)) ([3cb8b79](https://github.com/viamin/paid/commit/3cb8b791131d7258073d567a8dd845bfb7a66a91))


### Bug Fixes

* 692: fix(knowledge): distinguish 'tool unavailable' from 'no results' in collector runs ([#751](https://github.com/viamin/paid/issues/751)) ([ced21ca](https://github.com/viamin/paid/commit/ced21cafdb1dfeaebd3a47bbb0a9ae699ea9100f))
* 694: feat(orchestration): implement PlanningWorkflow for feature decomposition ([#752](https://github.com/viamin/paid/issues/752)) ([19700bf](https://github.com/viamin/paid/commit/19700bf7131aad3544811df85f45b59125764f19))
* 699: feat(orchestration): aggregated PR creation for multi-agent features ([#759](https://github.com/viamin/paid/issues/759)) ([074179a](https://github.com/viamin/paid/commit/074179afef1fbcc18764247ab68fc842cb4b6c09))
* 700: feat(guardrails): implement infinite loop detection for agent runs ([#757](https://github.com/viamin/paid/issues/757)) ([dd025c7](https://github.com/viamin/paid/commit/dd025c740a945bf0b147e96db6af6be38adf81f0))
* 702: feat(guardrails): enforce cost limits per project with hard stop ([#763](https://github.com/viamin/paid/issues/763)) ([ca567e2](https://github.com/viamin/paid/commit/ca567e249e1b711d2bbc4d45e1d59673c42a14db))
* 756: Clicking timeframe buttons on dashboard resets page scroll position ([#764](https://github.com/viamin/paid/issues/764)) ([c3471e3](https://github.com/viamin/paid/commit/c3471e3406c7c4efcd42e0913bf66c56140db4e2))
* **dashboard:** show resolved provider names ([#775](https://github.com/viamin/paid/issues/775)) ([9aa912e](https://github.com/viamin/paid/commit/9aa912e8ba48f98811cb88f7713614acf14d14bc))
* **dev:** add supervisor diagnostics for overmind shutdowns ([3e8f3cf](https://github.com/viamin/paid/commit/3e8f3cf5ac7cc256d23209339f66ee8599adfc86))
* **dev:** add supervisor diagnostics for overmind shutdowns ([f504eae](https://github.com/viamin/paid/commit/f504eae9d54d5bafcf895afa15f720aba5b9f114))
* **dev:** force temporal worker shutdown after grace period ([4cd7174](https://github.com/viamin/paid/commit/4cd7174babe4a12ff93a3118e6a9c7c2a04428ed))
* **dev:** force temporal worker shutdown after grace period ([3eaf0b1](https://github.com/viamin/paid/commit/3eaf0b123ea0306832aff4511943a76fb5a670ac))
* **dev:** harden auto-update overmind recovery ([9c3a44c](https://github.com/viamin/paid/commit/9c3a44c0403e1c7916ab3c9a9484349ed59f8fd7))
* **dev:** harden auto-update overmind recovery ([0d0b7c3](https://github.com/viamin/paid/commit/0d0b7c32a51521920d4142109b4e87a542ac2e2e))

## [0.14.2](https://github.com/viamin/paid/compare/v0.14.1...v0.14.2) (2026-04-02)


### Bug Fixes

* 685: Add time range filters to metrics and category/status filters to performance section ([#747](https://github.com/viamin/paid/issues/747)) ([52f95c6](https://github.com/viamin/paid/commit/52f95c6626e66a74b4a9c56b9510de705679ab79))
* 689: Make tables horizontally scrollable on mobile devices ([#748](https://github.com/viamin/paid/issues/748)) ([1289066](https://github.com/viamin/paid/commit/1289066233e8f375b74425840893759dd9e0ffd1))
* 690: feat(knowledge): install ruby-maat gem and wire up ChurnHotspotCollector ([#750](https://github.com/viamin/paid/issues/750)) ([d5cc546](https://github.com/viamin/paid/commit/d5cc546f9115c8acb9404f128d02deaf23cc36d0))
* 691: fix(knowledge): RoutesCollector reads a file that nothing generates ([#749](https://github.com/viamin/paid/issues/749)) ([ded1b6d](https://github.com/viamin/paid/commit/ded1b6de4000a8611f56e2cb2beb3fd7811c2721))
* 695: feat(orchestration): create sub-issues in GitHub from decomposed plan ([#753](https://github.com/viamin/paid/issues/753)) ([7bd8ad9](https://github.com/viamin/paid/commit/7bd8ad9b05dd15de7b42013594db26539fb7241b))
* 696: feat(orchestration): parallel AgentExecutionWorkflow invocation ([#755](https://github.com/viamin/paid/issues/755)) ([0c8b164](https://github.com/viamin/paid/commit/0c8b164af1c287c38080710013c55db739664e2e))
* **knowledge:** show specific error details when collection fails ([#746](https://github.com/viamin/paid/issues/746)) ([478e283](https://github.com/viamin/paid/commit/478e28304c8ea537fe696d1a79e8f94c784c44bb))

## [0.14.1](https://github.com/viamin/paid/compare/v0.14.0...v0.14.1) (2026-04-02)


### Bug Fixes

* 656: Add project setting to append provider co-authored-by to agent run commits ([#675](https://github.com/viamin/paid/issues/675)) ([78f1150](https://github.com/viamin/paid/commit/78f11502e325bc039f3c8791d53629e782585fc2))
* 683: Issue status should reflect overall lifecycle, not latest agent run status ([#744](https://github.com/viamin/paid/issues/744)) ([a7d6a7a](https://github.com/viamin/paid/commit/a7d6a7a7127dbb7b66100e7d179b6ef0deaddf72))
* 693: fix(knowledge): ContainerizedRunner bind mount is empty in DinD/DooD environments ([#743](https://github.com/viamin/paid/issues/743)) ([eb1abbf](https://github.com/viamin/paid/commit/eb1abbf09e61a6cf73ee337bad59c0ffb7fb07f3))
* **knowledge:** add fetch refspec to bare clones so staleness detection works ([#688](https://github.com/viamin/paid/issues/688)) ([d92d9c3](https://github.com/viamin/paid/commit/d92d9c3d2fe4c0445085a2b15dc41a936ff1a300))

## [0.14.0](https://github.com/viamin/paid/compare/v0.13.0...v0.14.0) (2026-04-01)


### Features

* **knowledge:** add semantic search settings UI to knowledge base page ([#687](https://github.com/viamin/paid/issues/687)) ([7a9b25d](https://github.com/viamin/paid/commit/7a9b25d6bf506feef17438d70f1b79b8b8447bdb))


### Bug Fixes

* 652: Diagnosis: Agent Run [#3576](https://github.com/viamin/paid/issues/3576) — Fix [#637](https://github.com/viamin/paid/issues/637): fix(providers): redesign API key compatibility model to separate CLI tools from API services ([#676](https://github.com/viamin/paid/issues/676)) ([770da28](https://github.com/viamin/paid/commit/770da28c81a48123162efa0f04f7bfc02686d707))
* 672: Add ability to cancel in-progress agent runs ([#677](https://github.com/viamin/paid/issues/677)) ([25ba7ea](https://github.com/viamin/paid/commit/25ba7ea39209382f3cdeb691196eda70a25911a4))
* 680: feat(knowledge): wire user OpenAI API key into search embeddings and surface key status in knowledge base UI ([#682](https://github.com/viamin/paid/issues/682)) ([c0f6c1a](https://github.com/viamin/paid/commit/c0f6c1a975a01e27f767dc6ae6382b0680f6cfc6))

## [0.13.0](https://github.com/viamin/paid/compare/v0.12.0...v0.13.0) (2026-04-01)


### Features

* **issues:** parse parent-child relationships from body/comments ([#671](https://github.com/viamin/paid/issues/671)) ([fd519f9](https://github.com/viamin/paid/commit/fd519f9bd8e3bd2d16fe00cf05fd931a4301c04a))
* **security:** add package age quarantine to bin/update ([de87d75](https://github.com/viamin/paid/commit/de87d750422f6b45a6f492a3eec13fb3380529fc))


### Bug Fixes

* 619: chore: Remove redundant Dependabot alert scanning code ([#650](https://github.com/viamin/paid/issues/650)) ([55b2269](https://github.com/viamin/paid/commit/55b226907782bc8498640978a04de4ff8d97102e))
* 637: fix(providers): redesign API key compatibility model to separate CLI tools from API services ([#651](https://github.com/viamin/paid/issues/651)) ([e3c5312](https://github.com/viamin/paid/commit/e3c5312a645ecfcc6a6ea9f1dc702ffa9074462d))
* 653: fix(ui): Auto-pick lightning bolt icon not restored after failed agent run ([#658](https://github.com/viamin/paid/issues/658)) ([3ff4caa](https://github.com/viamin/paid/commit/3ff4caaacff1f4efecdee46fa5744ce4df23992f))
* 655: Diagnosis: Agent Run [#3588](https://github.com/viamin/paid/issues/3588) ([#657](https://github.com/viamin/paid/issues/657)) ([18104d0](https://github.com/viamin/paid/commit/18104d0549c501ab38a2c4ae726634c5b3edbc43))
* 664: Support custom pre-commit requirements (configurable at project/user/account level) ([#678](https://github.com/viamin/paid/issues/678)) ([dda2035](https://github.com/viamin/paid/commit/dda20352d0a0e74bef2d7c53dfaa489c343a981f))
* 666: Auto-retry timed out agent runs for issue goals ([#669](https://github.com/viamin/paid/issues/669)) ([e5593b6](https://github.com/viamin/paid/commit/e5593b611b1dd75140010efc62c947cb84ab24a5))
* 674: Break down performance metrics by outcome and goal type ([#679](https://github.com/viamin/paid/issues/679)) ([d64eef0](https://github.com/viamin/paid/commit/d64eef0273f587d92f3c247bec98fd114afd35ce))
* **db:** restore schema.rb emptied by merge conflict misresolution ([5d2b145](https://github.com/viamin/paid/commit/5d2b145dbd9badc3b99c03cb9f5d92f4d400f556))
* **db:** restore schema.rb emptied by merge conflict misresolution ([1679fe0](https://github.com/viamin/paid/commit/1679fe01e62d2cbecb54bad5d01443279632f9df))
* **db:** use correct pool key and raise default connection pool to 20 ([1ee6f4d](https://github.com/viamin/paid/commit/1ee6f4dcc917fbd17ac298e18fda187d65da0614))
* **db:** use correct pool key and raise default to 20 ([6fe40e2](https://github.com/viamin/paid/commit/6fe40e20c33b92b5ce397336663abd3a98cfda35))
* **security:** address PR review feedback and update Cursor checksum ([47db98a](https://github.com/viamin/paid/commit/47db98ac5087ca254024abb748a9cd2d6ca2c480))
* **security:** harden npm/bundler supply chain against dependency attacks ([2b6399a](https://github.com/viamin/paid/commit/2b6399a122a2fad0103b700830cea1be76717d22))
* **security:** harden npm/bundler supply chain against dependency attacks ([991a478](https://github.com/viamin/paid/commit/991a478adf0d2cefbf661fd409d25d1d2b507588))
* **security:** review fixes for package age quarantine ([0a558f6](https://github.com/viamin/paid/commit/0a558f6c59fb45b0e2cc699123120c1257c11c9c))

## [0.12.0](https://github.com/viamin/paid/compare/v0.11.4...v0.12.0) (2026-03-31)


### Features

* **providers:** support per-entry OpenCode model routing ([#621](https://github.com/viamin/paid/issues/621)) ([d228cde](https://github.com/viamin/paid/commit/d228cde7dfe0ba0c7e02b7b8b69515f466bad598))


### Bug Fixes

* 413: Phase 2: Intelligence — remaining work tracker ([#608](https://github.com/viamin/paid/issues/608)) ([d6031ff](https://github.com/viamin/paid/commit/d6031ff358f355ddef24eacc73146609c984e8e6))
* 615: Prevent auto-pick from selecting tracker issues with incomplete or transitive blockers ([#630](https://github.com/viamin/paid/issues/630)) ([d943246](https://github.com/viamin/paid/commit/d943246a7a225e2ec1e6ac241de368e5d42eba0e))
* 618: feat: Add periodic CodeQL code scanning alert monitoring ([#633](https://github.com/viamin/paid/issues/633)) ([74748bb](https://github.com/viamin/paid/commit/74748bb726769b8cbeec3db5d9541f91d404f3c1))
* 628: Unpausing a PR does not clear paused status pill or enqueue an agent run ([#647](https://github.com/viamin/paid/issues/647)) ([ef9ae4d](https://github.com/viamin/paid/commit/ef9ae4df833c4e6068c776bdf96424a665125755))
* 632: fix: Retry runs copy stale auto-generated prompt, ignoring updated service containers ([#648](https://github.com/viamin/paid/issues/648)) ([9e3388d](https://github.com/viamin/paid/commit/9e3388d9873903a19c9d89c77533df994ce2609c))
* 635: Add configurable PR review settings to projects ([#649](https://github.com/viamin/paid/issues/649)) ([8b879d7](https://github.com/viamin/paid/commit/8b879d74247286196b1e8a9bef6585db8fc7cd63))
* 636: feat(api-keys): allow editing provider API keys after creation ([#646](https://github.com/viamin/paid/issues/646)) ([6fb9236](https://github.com/viamin/paid/commit/6fb9236d5dcc5166539f6711b3677fafaaf8c5c4))
* 639: feat(knowledge): Wire embedding pipeline to use user's ProviderApiKey ([#645](https://github.com/viamin/paid/issues/645)) ([276f56e](https://github.com/viamin/paid/commit/276f56e1bed061f7367ebf32754cbb49d3181346))
* **dashboard:** normalize claude_code to claude in effective provider ([#638](https://github.com/viamin/paid/issues/638)) ([f7faddd](https://github.com/viamin/paid/commit/f7faddd5ae3708512005d1f48e20cf7b5c37883e))
* **knowledge:** remove empty Qdrant API key that blocks dev connections ([7351c19](https://github.com/viamin/paid/commit/7351c19ead8bbd4b890085be6ea87b0ea9ed9c30))
* **providers:** make provider table horizontally scrollable on mobile ([#626](https://github.com/viamin/paid/issues/626)) ([#634](https://github.com/viamin/paid/issues/634)) ([8ad6383](https://github.com/viamin/paid/commit/8ad6383fb330471a2693b3f0a01bc0fcd262905e))
* **providers:** resolve Gemini agent test timeouts ([#624](https://github.com/viamin/paid/issues/624)) ([3102da2](https://github.com/viamin/paid/commit/3102da2c073bac2dcc1ca32036bca46eede07ee7))

## [0.11.4](https://github.com/viamin/paid/compare/v0.11.3...v0.11.4) (2026-03-30)


### Bug Fixes

* 262: Redaction Pipeline — Sensitive Data Handling Before Embedding ([#620](https://github.com/viamin/paid/issues/620)) ([f6d20aa](https://github.com/viamin/paid/commit/f6d20aa485be3219ca77d47aeb92e0a79688e5c2))
* 607: Add "Diagnose Error" option on agent run page when an error occurs ([#613](https://github.com/viamin/paid/issues/613)) ([9c7d270](https://github.com/viamin/paid/commit/9c7d2702d52f939d977800d9b19598477f5dc088))
* **agent-harness:** reconcile [#595](https://github.com/viamin/paid/issues/595)/[#596](https://github.com/viamin/paid/issues/596) with released upstream changes ([#629](https://github.com/viamin/paid/issues/629)) ([e4e8ca4](https://github.com/viamin/paid/commit/e4e8ca464227364a4f40871e90837bc4f393326a)), closes [#614](https://github.com/viamin/paid/issues/614)

## [0.11.3](https://github.com/viamin/paid/compare/v0.11.2...v0.11.3) (2026-03-30)


### Bug Fixes

* 268: Trigger Knowledge Collection on Project Creation ([#603](https://github.com/viamin/paid/issues/603)) ([0efcabd](https://github.com/viamin/paid/commit/0efcabd6326c0dc998f44d713a96149e8e83fbc0))
* 269: Knowledge Base Safe Defaults and Security Hardening ([#611](https://github.com/viamin/paid/issues/611)) ([3c46d64](https://github.com/viamin/paid/commit/3c46d64f31d6ff3b1de514f0fc931c62da64f8a2))
* 591: Consolidate Dashboard and Live Dashboard into a single page ([#605](https://github.com/viamin/paid/issues/605)) ([11a2865](https://github.com/viamin/paid/commit/11a286594fca48a3148f5bf7a1004723950069d5))
* 592: Add a comment when auto-merging a PR ([#606](https://github.com/viamin/paid/issues/606)) ([85436ea](https://github.com/viamin/paid/commit/85436ea9e073429ab4ea06ef92ff9698e3d6895b))
* 593: Improve Temporal recovery for interrupted agent runs during full dev updates ([#604](https://github.com/viamin/paid/issues/604)) ([5a61264](https://github.com/viamin/paid/commit/5a612641b7e261bd5a190208d9637afa93ce2fcb))
* 595: Track agent-harness provider audit and reduce Paid-side provider special casing ([#600](https://github.com/viamin/paid/issues/600)) ([761a8dd](https://github.com/viamin/paid/commit/761a8dd07736e97779fcd2fad4bd66104d1383f4))
* 596: Track upstream Codex container-execution fix in agent-harness and adopt it in Paid ([#602](https://github.com/viamin/paid/issues/602)) ([ec19561](https://github.com/viamin/paid/commit/ec1956135bd2094a3178fec3efb718c98aa1744e))
* 609: Retain unknown failed agent-run containers briefly after successful agent execution ([#612](https://github.com/viamin/paid/issues/612)) ([a999bdf](https://github.com/viamin/paid/commit/a999bdfe5d9e44a7b513e09c2dbcddcabaca9636))
* **containers:** normalize git push error encoding ([#610](https://github.com/viamin/paid/issues/610)) ([1c7a1f6](https://github.com/viamin/paid/commit/1c7a1f6c01ea5768e2f8ee9b43d084ca49559e2f))
* **db:** normalize schema.rb partial index formatting ([bbbe069](https://github.com/viamin/paid/commit/bbbe069a3496f44242694fde4703d570afe92a61))
* **db:** normalize schema.rb partial index WHERE clause formatting ([a8d14ed](https://github.com/viamin/paid/commit/a8d14edea5b510463e51f5b06234bc21aa8de965))
* **issue-monitoring:** keep Temporal poll workers within DB capacity ([#617](https://github.com/viamin/paid/issues/617)) ([ff6cf54](https://github.com/viamin/paid/commit/ff6cf54f70dafce13cac0a8ea038f2fc726bc386))

## [0.11.2](https://github.com/viamin/paid/compare/v0.11.1...v0.11.2) (2026-03-29)


### Bug Fixes

* **agent-runs:** bypass codex sandbox in agent containers ([a590342](https://github.com/viamin/paid/commit/a590342d866173a75a3ab9afc59bdb37813237e1))
* **agent-runs:** bypass codex sandbox in agent containers ([51be01b](https://github.com/viamin/paid/commit/51be01be7c3f4dfdb250c5c7af4dbf4c60ebc3e0))
* **dev:** pass startup cleanup grace period to relaunched bin/dev ([499d1b3](https://github.com/viamin/paid/commit/499d1b3606784ba7f0406a294406218c6d57ca08))
* **dev:** preserve recent runs across full dev updates ([e7f25e8](https://github.com/viamin/paid/commit/e7f25e887786d12482f08c831474525a90b9854f))
* **dev:** preserve recent runs across full dev updates ([525a4d0](https://github.com/viamin/paid/commit/525a4d0678af0ba72a084b646393ed229000bbba))
* **dev:** recover from dead overmind processes ([0d5a8e7](https://github.com/viamin/paid/commit/0d5a8e7f1c1e3506ef54c77b1426da1fde1c8895))
* **dev:** recover from dead overmind processes ([2407202](https://github.com/viamin/paid/commit/240720262224d4da98e8bb437daccb9dca2571fb))
* **providers:** reuse codex runtime command in tests ([094e5ae](https://github.com/viamin/paid/commit/094e5ae9a488a3933bc4ba70675f769f410d3a5f))

## [0.11.1](https://github.com/viamin/paid/compare/v0.11.0...v0.11.1) (2026-03-29)


### Bug Fixes

* 260: Agent Context Bundle Builder for Agent-Harness Consumption ([#587](https://github.com/viamin/paid/issues/587)) ([290cba1](https://github.com/viamin/paid/commit/290cba1c67bd970a2461219ead4e2e66ab040bf6))
* 580: Show PR link instead of quick run button for synced issues with active PRs ([#585](https://github.com/viamin/paid/issues/585)) ([9a5d581](https://github.com/viamin/paid/commit/9a5d581dd2fb3d3d5e68d52796021f0acbd9936f))
* 581: PR descriptions should summarize full scope and purpose, not just recent work ([#583](https://github.com/viamin/paid/issues/583)) ([b516a35](https://github.com/viamin/paid/commit/b516a35f6a9816ab4a60621e2c74864aad0798dc))
* 584: Handle no-output issue runs with explicit needs-input / recommend-close follow-up ([#586](https://github.com/viamin/paid/issues/586)) ([408e118](https://github.com/viamin/paid/commit/408e118748756eedd71207972f94d4ff2f89b2ad))
* **containers:** remove attached volumes during cleanup ([#590](https://github.com/viamin/paid/issues/590)) ([8045ae4](https://github.com/viamin/paid/commit/8045ae42f55fac1b4224c65f07725bdf44302f00))
* **dev:** isolate overmind from bundler env ([#588](https://github.com/viamin/paid/issues/588)) ([af87de9](https://github.com/viamin/paid/commit/af87de95826bdeb847b621c2ae4690b1edfd635e))

## [0.11.0](https://github.com/viamin/paid/compare/v0.10.0...v0.11.0) (2026-03-28)


### Features

* **providers:** improve Test Agent reliability and auth messaging ([#568](https://github.com/viamin/paid/issues/568)) ([8857a95](https://github.com/viamin/paid/commit/8857a95732019b9e780d43ac38df6f1785337345))


### Bug Fixes

* 248: Document service container architecture and operator setup guide ([#566](https://github.com/viamin/paid/issues/566)) ([085d155](https://github.com/viamin/paid/commit/085d155a87f26f262996eaecfdaa3c4c1e67c59f))
* 261: Decision Records — Why Capture Integrated into Agent Workflows ([#572](https://github.com/viamin/paid/issues/572)) ([01fa998](https://github.com/viamin/paid/commit/01fa998ebf74206ed268765c3808eb10fd73e969))
* 264: Minimal Admin UI — Inspect Knowledge Artifacts, Collector Runs, and Search ([#574](https://github.com/viamin/paid/issues/574)) ([ee52b7f](https://github.com/viamin/paid/commit/ee52b7fe806a7696da29d107710a55e4c2c55cbb))
* 265: Staleness Detection and Re-collection Triggers ([#573](https://github.com/viamin/paid/issues/573)) ([96eb7f6](https://github.com/viamin/paid/commit/96eb7f6edf9c45d0916f6639183b8d0af0333df2))
* 267: Knowledge Base Architecture Docs and Operational Runbook ([#576](https://github.com/viamin/paid/issues/576)) ([37a9b1e](https://github.com/viamin/paid/commit/37a9b1e590e1c765d527a05576a6cbb0ddf2c8aa))
* 402: feat(providers): add Cursor support to paid-agent containers ([#562](https://github.com/viamin/paid/issues/562)) ([28413d4](https://github.com/viamin/paid/commit/28413d4cb9187afe596f493858381584072140a6))
* 404: feat(providers): add GitHub Copilot support to paid-agent containers ([#564](https://github.com/viamin/paid/issues/564)) ([38e18b0](https://github.com/viamin/paid/commit/38e18b0cb6c33c4b7cafd77b5a5a47103999e397))
* 405: feat(providers): add Aider support to paid-agent containers ([#565](https://github.com/viamin/paid/issues/565)) ([3af495e](https://github.com/viamin/paid/commit/3af495ebb9b3030cb3b305bca1c64e1c7f7e698d))
* 452: feat(agent-runs): add scope analysis heuristic to detect decomposable features ([#570](https://github.com/viamin/paid/issues/570)) ([f3cd3cc](https://github.com/viamin/paid/commit/f3cd3cc388349a72e0a50c47ee9ae1cf4c75835c))
* 546: feat(providers): allow multiple provider entries with different auth types (subscription vs API key) ([#559](https://github.com/viamin/paid/issues/559)) ([b3db2ba](https://github.com/viamin/paid/commit/b3db2ba728b220ae603a16bd68a2e20ed9f1cda8))
* 549: Clean up persistent dev-update logs ([#575](https://github.com/viamin/paid/issues/575)) ([30b2af5](https://github.com/viamin/paid/commit/30b2af562f63e92e7f8edeb964577d36c8f5e1be))
* 550: feat(mcp): add persisted MCP server definitions, project associations, and run snapshots ([#571](https://github.com/viamin/paid/issues/571)) ([48f59fa](https://github.com/viamin/paid/commit/48f59faba32eb0a31c3f67735db23f2496726096))
* 563: Move delete project button into edit form with name confirmation ([#577](https://github.com/viamin/paid/issues/577)) ([b3e3b20](https://github.com/viamin/paid/commit/b3e3b2047c1d996694e332babd790ce7613cef8e))
* 578: Hide pause button for PRs without paid-automation enabled ([#579](https://github.com/viamin/paid/issues/579)) ([7a638d3](https://github.com/viamin/paid/commit/7a638d3220a0959f0823c40d5fbf74a0d8dc2be5))
* **dev:** capture overmind and tmux diagnostics ([#582](https://github.com/viamin/paid/issues/582)) ([b36d46d](https://github.com/viamin/paid/commit/b36d46ddefa24a8c2f406eced1a346f2750adfde))
* **prompts:** align service guidance with configured containers ([#569](https://github.com/viamin/paid/issues/569)) ([9da3a12](https://github.com/viamin/paid/commit/9da3a12aa1c1cb6ac5d7378ca4f6aac84d693b93))

## [0.10.0](https://github.com/viamin/paid/compare/v0.9.5...v0.10.0) (2026-03-28)


### Features

* add qdrant test integration coverage ([#524](https://github.com/viamin/paid/issues/524)) ([c5f1b46](https://github.com/viamin/paid/commit/c5f1b46ec070edc7edbd6f937ae7830393bb0caa))
* **agent-runs:** queue auto-pick work ahead of spare capacity ([#533](https://github.com/viamin/paid/issues/533)) ([3235016](https://github.com/viamin/paid/commit/3235016901437647718137679e5afc7d3965a405))
* **integrations:** restore hub and add credential catalog ([#539](https://github.com/viamin/paid/issues/539)) ([bfedfdc](https://github.com/viamin/paid/commit/bfedfdc92740bd2d4d4b713ce7f09bfdb9efa9ea))


### Bug Fixes

* 147: implement live operations dashboard ([#531](https://github.com/viamin/paid/issues/531)) ([e97d9c1](https://github.com/viamin/paid/commit/e97d9c1b7ea3c9f337469f426665594d9c8e81fd))
* 263: Provenance Tracking and Audit Log ([#522](https://github.com/viamin/paid/issues/522)) ([5ac5331](https://github.com/viamin/paid/commit/5ac53310445ac349208eaf87599b4a32edbb3112))
* 525: Expose automation settings in project configuration section ([#529](https://github.com/viamin/paid/issues/529)) ([68245e4](https://github.com/viamin/paid/commit/68245e403f4fe06e0b27b41b387f6505d1fcd800))
* 535: Consolidate Configuration and Automation sections in the project page ([#555](https://github.com/viamin/paid/issues/555)) ([5461090](https://github.com/viamin/paid/commit/5461090dd774b500c0e09211a311e6ae10dd750b))
* 536: Expand quality metrics to all agent run goal types and add PR interaction signals ([#541](https://github.com/viamin/paid/issues/541)) ([ee81c30](https://github.com/viamin/paid/commit/ee81c3030f7c4889a6287dbbad4ccfdbbae3086f))
* 544: Add pause/resume functionality for auto-continue on individual PRs ([#558](https://github.com/viamin/paid/issues/558)) ([da0cd5e](https://github.com/viamin/paid/commit/da0cd5e132ca6d547ad1ef1545c5d71762f03de4))
* 545: Allow disabling individual providers as fallback providers ([#556](https://github.com/viamin/paid/issues/556)) ([a37593e](https://github.com/viamin/paid/commit/a37593e1b55b158f7b2fa0a72848c2c24ce4552e))
* 547: Dashboard metrics should count fallback provider usage for agent runs ([#560](https://github.com/viamin/paid/issues/560)) ([12cbb05](https://github.com/viamin/paid/commit/12cbb0518dfa88caf8621ce241f00e1d4f429ed2))
* **build:** install ast-grep from release binaries ([46af202](https://github.com/viamin/paid/commit/46af2022848da5fea1e0886fc93b7beef7c9bacb))
* **build:** install ast-grep from release binaries ([8378ae3](https://github.com/viamin/paid/commit/8378ae330b891b47e324a894bdd060832219d156))
* **dev-update:** preserve restart diagnostics across setup ([43aae85](https://github.com/viamin/paid/commit/43aae855187ed152e5e9ed9d8abc61766e28e5c5))
* **dev-update:** preserve restart diagnostics across setup ([ecbadec](https://github.com/viamin/paid/commit/ecbadece4647c8bae309a0c1a30d9629391ea64a))
* **devcontainer:** export OVERMIND_SOCKET so any terminal can reach overmind ([f5b490c](https://github.com/viamin/paid/commit/f5b490c49d6eb6fd7a536e899dde81de4668aa1d))
* **github-sync:** fetch automation-labeled pull requests ([#537](https://github.com/viamin/paid/issues/537)) ([f36e124](https://github.com/viamin/paid/commit/f36e124ae87875c4ff42503120b82d698514a414))
* **github-sync:** sync all issues and gate automation by labels ([#542](https://github.com/viamin/paid/issues/542)) ([93277b3](https://github.com/viamin/paid/commit/93277b364e03ef495ad7d3071a4b0a69ba96ecb8))
* run provider tests in real container context ([#538](https://github.com/viamin/paid/issues/538)) ([7bbf433](https://github.com/viamin/paid/commit/7bbf4331598ca6337ac39349f1b5309827d21b4e))
* **service-containers:** add postgres health checks and metrics ([#557](https://github.com/viamin/paid/issues/557)) ([5f4c2b3](https://github.com/viamin/paid/commit/5f4c2b3f87b98ec9af2462ab13c260d7bffbd2cc))
* **setup:** make solid cable setup idempotent ([b55b250](https://github.com/viamin/paid/commit/b55b250b07af48c72af08108acc6e1687e175a59))
* **setup:** make solid cable setup idempotent ([b1a797d](https://github.com/viamin/paid/commit/b1a797db45f5532662a5e3960840f4e3454ac432))

## [0.9.5](https://github.com/viamin/paid/compare/v0.9.4...v0.9.5) (2026-03-26)


### Bug Fixes

* 523: Rename "Tokens" menu to "Integrations" and modularize token types ([#528](https://github.com/viamin/paid/issues/528)) ([0ed8d73](https://github.com/viamin/paid/commit/0ed8d73fe71bead57d8b337b12ef5e936a6f78d2))
* **dev-update:** restart overmind processes when healthy ([8b57cbb](https://github.com/viamin/paid/commit/8b57cbbd53978154b6e41e1bd72d64ef3e97cc03))
* **dev-update:** restart overmind processes when healthy ([c31324e](https://github.com/viamin/paid/commit/c31324ee1faf0fd160ddf3214c0fe8e79b496add))
* speed up slow specs ([d8530d3](https://github.com/viamin/paid/commit/d8530d3422c8c94bd8c8a31a96611b17f1b4e14c))
* stabilize search specs and install ast-grep ([315ecb9](https://github.com/viamin/paid/commit/315ecb9164474b4df11dc893765f5ba2f3f76588))
* stabilize search specs and install ast-grep ([266c2e3](https://github.com/viamin/paid/commit/266c2e343800d21c0eb92073f60260cf10f2cd24))
* **tests:** skip collector integration specs when ast-grep is not installed ([3b2b889](https://github.com/viamin/paid/commit/3b2b88910c5742e31336849052b65e2db0526f60))

## [0.9.4](https://github.com/viamin/paid/compare/v0.9.3...v0.9.4) (2026-03-26)


### Bug Fixes

* **dev-update:** harden full restart logging and recovery ([67ace9c](https://github.com/viamin/paid/commit/67ace9c72dcb61776eee304078613463d8cba930))
* **dev-update:** harden full restart logging and recovery ([cc3549e](https://github.com/viamin/paid/commit/cc3549e82b7d3140ce83d70cc068fd7a99e91d02))
* **dev:** allow tailscale hosts with ports ([6f971f3](https://github.com/viamin/paid/commit/6f971f3465cb3883fe8c483d16460ea3dae2ad2d))
* **spec:** avoid race when asserting dev start log ([66b3348](https://github.com/viamin/paid/commit/66b3348c98d6c61882c330fd3a5287c310068568))
* **spec:** use exec tmpdir for dev-update script tests ([73f74e2](https://github.com/viamin/paid/commit/73f74e277267af6e898de240ca10e71281ba40e4))

## [0.9.3](https://github.com/viamin/paid/compare/v0.9.2...v0.9.3) (2026-03-26)


### Bug Fixes

* 254: Thin Vertical Slice — Routes Collector → Postgres → Qdrant → Query API ([#513](https://github.com/viamin/paid/issues/513)) ([5b5dcce](https://github.com/viamin/paid/commit/5b5dccee7a1c366bf6a73dcb2d7d6b2225e0cba9))
* 255: Static Collectors — ast-grep Symbols, Dependencies, Config Keys ([#508](https://github.com/viamin/paid/issues/508)) ([e95afc3](https://github.com/viamin/paid/commit/e95afc35a173f23ef4a431364d8fb2df9931a40d))
* 256: Analytical Collectors — ruby-maat Churn/Hotspots + scc Language Stats ([#507](https://github.com/viamin/paid/issues/507)) ([177cbfd](https://github.com/viamin/paid/commit/177cbfd81f779d479b7dcc4fd96dac55e0108665))
* 257: Embedding Pipeline — Chunking, Generation via Agent-Harness, Qdrant Upsert ([#506](https://github.com/viamin/paid/issues/506)) ([37c0200](https://github.com/viamin/paid/commit/37c0200539db6166c594c9d5a67ea6ff5356a05f))
* 258: Containerized Collector Execution via Agent-Harness ([#516](https://github.com/viamin/paid/issues/516)) ([9ba39a4](https://github.com/viamin/paid/commit/9ba39a40ee3a70b1571c3660242528814ac08782))
* 259: Retrieval API — Hybrid Search with Exact + Semantic + Re-ranking ([#518](https://github.com/viamin/paid/issues/518)) ([3854356](https://github.com/viamin/paid/commit/385435688588148509d84dfb7cd57899c2b04916))
* 266: Postgres Full-Text and Trigram Search Setup for Knowledge Base ([#509](https://github.com/viamin/paid/issues/509)) ([65b356d](https://github.com/viamin/paid/commit/65b356dc96d4591c8db8ead1a8c48224e6997133))
* 295: Add configurable "paid-automation" label for automatic issue/PR handling ([#505](https://github.com/viamin/paid/issues/505)) ([fdaaf22](https://github.com/viamin/paid/commit/fdaaf22f471e747c9c6707c2266684430c5ebf51))
* 410: Implement automatic style guide extraction from codebase ([#517](https://github.com/viamin/paid/issues/517)) ([d11ef70](https://github.com/viamin/paid/commit/d11ef707d3dcd0eefda39f78b98b414513cd9591))
* 411: Add tree-sitter integration for structural code analysis ([#514](https://github.com/viamin/paid/issues/514)) ([9a0f13d](https://github.com/viamin/paid/commit/9a0f13dd24a8387adabdce7048bf2a83d528b99d))
* 412: Add human feedback collection via GitHub reactions and webhooks ([#515](https://github.com/viamin/paid/issues/515)) ([bbc8a05](https://github.com/viamin/paid/commit/bbc8a05c6a171aedfccace304052a540f23c71ba))
* **dev-update:** recover from stale overmind sockets ([e81d09b](https://github.com/viamin/paid/commit/e81d09baf809c56d15d26285989f7db1bae4e74a))
* **dev-update:** recover from stale overmind sockets ([1bd6ad4](https://github.com/viamin/paid/commit/1bd6ad4a845bc98dbd963c49c72818f03ef880b9))
* **devcontainer:** set PAID_REPO_FULL_NAME so auto-update triggers ([25ff2b6](https://github.com/viamin/paid/commit/25ff2b6ae7b28b3efd379ee3f53db71935798344))
* **devcontainer:** set PAID_REPO_FULL_NAME so auto-update triggers ([d5eff8f](https://github.com/viamin/paid/commit/d5eff8fda7c8767866852a3d7ce87df82aa9c639))
* **dev:** recover from stale overmind sockets ([78ca403](https://github.com/viamin/paid/commit/78ca403a10d431fa52ed50d11ac54268aa2224c0))

## [0.9.2](https://github.com/viamin/paid/compare/v0.9.1...v0.9.2) (2026-03-26)


### Bug Fixes

* 488: fix(issue-goal): preserve drafted issue content when direct GitHub issue creation fails ([#500](https://github.com/viamin/paid/issues/500)) ([217cb65](https://github.com/viamin/paid/commit/217cb6567a83c2b7846caeba35b5da1208b07651))
* 489: Auto-update dev environment when PRs are auto-merged ([#496](https://github.com/viamin/paid/issues/496)) ([43d4990](https://github.com/viamin/paid/commit/43d49906cf908ca1d9e446ed5953a868f5599f9b))
* **agent-runs:** recover from timed out branch pushes ([#501](https://github.com/viamin/paid/issues/501)) ([5c7ecec](https://github.com/viamin/paid/commit/5c7ececff68fb2668b75a9fbca508b65cdf102c0))
* **agent-runs:** remove trigger column from agent runs table ([#502](https://github.com/viamin/paid/issues/502)) ([#504](https://github.com/viamin/paid/issues/504)) ([7354b77](https://github.com/viamin/paid/commit/7354b7798ab98d3e0e0a1ffc7dbc542a79081e3c))

## [0.9.1](https://github.com/viamin/paid/compare/v0.9.0...v0.9.1) (2026-03-26)


### Bug Fixes

* 246: Add service container lifecycle management: orphan cleanup, resource limits, and health monitoring ([#491](https://github.com/viamin/paid/issues/491)) ([cd30d96](https://github.com/viamin/paid/commit/cd30d96c5e9725f811c71f380b44f084c13cf003))
* 251: PostgreSQL Schema — Knowledge Objects, Versioning, Provenance ([#492](https://github.com/viamin/paid/issues/492)) ([1c3f0d2](https://github.com/viamin/paid/commit/1c3f0d2ed454b85a3043bb339953dde90f672688))
* 252: Qdrant Collection Management — Create, Upsert, Delete, Rebuild ([#494](https://github.com/viamin/paid/issues/494)) ([ef06e66](https://github.com/viamin/paid/commit/ef06e664e1e318dab31c8934b9c09e099b54877d))
* 253: Collector Framework — Orchestration, Storage, Idempotency, Staleness ([#493](https://github.com/viamin/paid/issues/493)) ([0271f00](https://github.com/viamin/paid/commit/0271f00add7c02873edf401044635b88cc26ccb1))
* 348: Add explanatory comment when applying `paid-escalated` label ([#480](https://github.com/viamin/paid/issues/480)) ([76fb684](https://github.com/viamin/paid/commit/76fb684744b566131dd35780ad6c025be02ad1ca))
* 430: feat(dependencies): parse dependency declarations from issue comments ([#476](https://github.com/viamin/paid/issues/476)) ([02f5759](https://github.com/viamin/paid/commit/02f57597e1a2402e6f7afc93186f0c4721245e1b))
* 479: Add visual indicator for auto-pickable issues on project page ([#481](https://github.com/viamin/paid/issues/481)) ([63add01](https://github.com/viamin/paid/commit/63add011b2b56155bf46d93d2e8487a50dcec8fb))
* 482: Remove standalone automation section from project page ([#484](https://github.com/viamin/paid/issues/484)) ([295e4dd](https://github.com/viamin/paid/commit/295e4dd9c197c49cbba648315d89e8b150a98226))
* 483: Add priority indicator to agent runs table priority column ([#497](https://github.com/viamin/paid/issues/497)) ([02b909a](https://github.com/viamin/paid/commit/02b909a8ecd580c5751239c3d31408b67b846b0a))
* 487: fix(agent-runs): update Codex CLI invocation for current codex version ([#498](https://github.com/viamin/paid/issues/498)) ([6560588](https://github.com/viamin/paid/commit/6560588de3baef9816c0ea9a89b9f6b029454524))
* **agent-runs:** disable Gemini CLI sandbox in agent containers ([#495](https://github.com/viamin/paid/issues/495)) ([6c2bb73](https://github.com/viamin/paid/commit/6c2bb7358a6469d2f54d007c1fd1735814455261)), closes [#490](https://github.com/viamin/paid/issues/490)

## [0.9.0](https://github.com/viamin/paid/compare/v0.8.0...v0.9.0) (2026-03-25)


### Features

* **agent-runs:** show PR/issue context instead of branch name in project runs table ([#469](https://github.com/viamin/paid/issues/469)) ([89e3880](https://github.com/viamin/paid/commit/89e388082281173035b928c78e128f06517cafee)), closes [#325](https://github.com/viamin/paid/issues/325)
* **projects:** auto-fix merge conflicts by default ([#474](https://github.com/viamin/paid/issues/474)) ([09d79fb](https://github.com/viamin/paid/commit/09d79fb88fe8e571738b03606c49e1909d99ebda))


### Bug Fixes

* 331: Fix Docker resource leaks from best-effort cleanup (paid-workspace volumes + exited containers) ([#470](https://github.com/viamin/paid/issues/470)) ([d99bf53](https://github.com/viamin/paid/commit/d99bf53b35ce8dba5716bd9b48a1b8ec85920cfd))
* 341: Replace hardcoded settings and ENV-based config with in-app configurable settings ([#471](https://github.com/viamin/paid/issues/471)) ([9714d60](https://github.com/viamin/paid/commit/9714d6086c1c36936976298280a84ba333bc0cdb))
* 344: Show associated projects on token pages with counter cache ([#457](https://github.com/viamin/paid/issues/457)) ([eac0eba](https://github.com/viamin/paid/commit/eac0eba9ed2775933dd097facf8045ee359e22ce))
* 429: feat(dependencies): support cross-project issue dependencies ([#473](https://github.com/viamin/paid/issues/473)) ([03b041d](https://github.com/viamin/paid/commit/03b041dd4f9fdfd2153615a0598c83131e83f289))
* 450: Track container CPU and memory metrics for automatic resource tuning ([#472](https://github.com/viamin/paid/issues/472)) ([9283aaf](https://github.com/viamin/paid/commit/9283aafa081caf02eaea968537af89fbe8321363))
* 461: feat(projects): show user-facing automation health instead of raw workflow status ([#466](https://github.com/viamin/paid/issues/466)) ([b683591](https://github.com/viamin/paid/commit/b6835916838c37018f329ddb25a84dd00fb2e7a4))
* 465: Add paid-auto-merged label to PRs merged via auto-merge ([#467](https://github.com/viamin/paid/issues/467)) ([47efcdb](https://github.com/viamin/paid/commit/47efcdb74fc4d121c61f573e6c8491fd8d916436))
* **auto-pick:** add periodic cron trigger for ProcessRunQueueJob ([83b459a](https://github.com/viamin/paid/commit/83b459aad4a089a2ec61f9b69589088f0ac0319d))
* **auto-pick:** add periodic cron trigger for ProcessRunQueueJob ([6147cc7](https://github.com/viamin/paid/commit/6147cc758ceaab1fd21116358bf0a4ef71f6a0aa))
* **ci:** smoke test the agent image build ([#463](https://github.com/viamin/paid/issues/463)) ([1c3e7c5](https://github.com/viamin/paid/commit/1c3e7c5ce539d9b9fb9c6604e5512958c2607c43))
* **ci:** split agent-image into a dedicated workflow ([#477](https://github.com/viamin/paid/issues/477)) ([72592fb](https://github.com/viamin/paid/commit/72592fb5b05746f573a22d20edcd977e7cfe0870))
* **pr-review:** break infinite review request loop when bot threads are resolved ([#478](https://github.com/viamin/paid/issues/478)) ([4f407ed](https://github.com/viamin/paid/commit/4f407ed945181bbc7182f9974dae3cb5c1eb7695))
* resolve merge conflict with main in fetch_issues_activity ([ffb28bd](https://github.com/viamin/paid/commit/ffb28bdcf5d493c4a0001a3996e81dc28568f931))
* **security:** address code review feedback ([886a9f0](https://github.com/viamin/paid/commit/886a9f0e719d7e564efa7f21c503938d1baa29a4))
* **security:** address review feedback on temporal coupling, timestamps, and class size ([c1d4ae7](https://github.com/viamin/paid/commit/c1d4ae780f670f5b9ec146611059260e2c279974))
* **security:** address review feedback on trusted login and alert timestamps ([f4cec40](https://github.com/viamin/paid/commit/f4cec40407156b05046d0365cbd7a62797df6c1f))
* **security:** unify severity prioritization across new and reopen candidates ([3482fb9](https://github.com/viamin/paid/commit/3482fb988f8321799f8b32f491ccaf4120838090))
* **security:** use alert timestamps for github_updated_at instead of Time.current ([098d284](https://github.com/viamin/paid/commit/098d2843bcca9898a074eb6fac3360ca84f396ec))
* **security:** use Issue constants instead of hardcoded source strings in auto_pick_spec ([13fb9f6](https://github.com/viamin/paid/commit/13fb9f6e504526ebd3b885ff76d36c2fc7c0dc1c))

## [0.8.0](https://github.com/viamin/paid/compare/v0.7.0...v0.8.0) (2026-03-25)


### Features

* **agent-runs:** link to GitHub review from agent run detail page ([#456](https://github.com/viamin/paid/issues/456)) ([c5faa63](https://github.com/viamin/paid/commit/c5faa630dd7431cd05e18d9747cc55992ea4a54c))
* **agent-runs:** replace Quick Run with Bump Priority button for PRs with active auto-continue runs ([5c7b58f](https://github.com/viamin/paid/commit/5c7b58fcba67c96a916a60b616033869129956b6)), closes [#347](https://github.com/viamin/paid/issues/347)
* **agent-runs:** show queue priority in agent run tables ([e84ab97](https://github.com/viamin/paid/commit/e84ab97ba17d740317cea3a217fc6eb11fd80a25)), closes [#345](https://github.com/viamin/paid/issues/345)
* **hooks:** add pre-commit check to reject commits with too many files ([fffdffb](https://github.com/viamin/paid/commit/fffdffbdd13fb0d1caba1200791eed99391cf50d)), closes [#441](https://github.com/viamin/paid/issues/441)
* **model-selection:** implement LLM meta-agent, UI, and per-project preferences ([b0955e0](https://github.com/viamin/paid/commit/b0955e0dd01616a2985debbb6a6064d5d713237e))
* **projects:** replace Auto-pick issues section with Automation section ([94504a0](https://github.com/viamin/paid/commit/94504a0c620d6617bcdeaef6b3689321601da53c)), closes [#419](https://github.com/viamin/paid/issues/419)
* **providers:** add Gemini support to paid-agent containers ([bacc3e4](https://github.com/viamin/paid/commit/bacc3e49195fd07b424be9cd95b73ce96e4f1885)), closes [#406](https://github.com/viamin/paid/issues/406)
* **providers:** add Kilocode support to paid-agent containers ([f2c74f6](https://github.com/viamin/paid/commit/f2c74f66aee2f9971703be24551cabc7915d902b))
* **ui:** convert UTC times to user's local timezone ([#386](https://github.com/viamin/paid/issues/386)) ([2742eb0](https://github.com/viamin/paid/commit/2742eb082d674fcc9aff8e13c7953315f9f8dd10))


### Bug Fixes

* 407: feat(providers): add OpenCode support to paid-agent containers ([#449](https://github.com/viamin/paid/issues/449)) ([b4d509f](https://github.com/viamin/paid/commit/b4d509f3fb60fe939b2601b1cc5fb306d2c16b9c))
* 455: feat(auto-pick): prefer unblocked leaf issues from dependency trees ([#459](https://github.com/viamin/paid/issues/459)) ([fae3de1](https://github.com/viamin/paid/commit/fae3de181e3d56e32e1bac3c38a8a9d330b62a04))
* **agent-image:** restore bin/setup Kilocode install ([3d78e24](https://github.com/viamin/paid/commit/3d78e24f46034b63fa0de5862f54e95d4cbe10bb))
* **agent-image:** restore bin/setup Kilocode install ([0e5a8b9](https://github.com/viamin/paid/commit/0e5a8b9a19289df7eb8186daa7195b634c63692b))
* **agent-runs:** address code review feedback for bump priority ([7d4c67f](https://github.com/viamin/paid/commit/7d4c67f6025d12b12b8477a1d2df1f219e2bcd54))
* **agent-runs:** address PR review feedback for priority badge naming and fallback ([44eb17c](https://github.com/viamin/paid/commit/44eb17c5dd248e94607d77e7db24f8ea39bedb84))
* **agent-runs:** address PR review feedback for priority badges ([ee96ca0](https://github.com/viamin/paid/commit/ee96ca0e791d672133803207f6856992f59072f0))
* **agent-runs:** address review feedback for bump priority feature ([f47b14b](https://github.com/viamin/paid/commit/f47b14bf9841cb453d363ae70e4609bb9ca97840))
* **agent-runs:** address review feedback for bump priority feature ([9ef5b00](https://github.com/viamin/paid/commit/9ef5b0078257c159eb5b3f3e7f79d6ab3520f861))
* **agent-runs:** address review feedback for bump priority UI and broadcasts ([9fb851c](https://github.com/viamin/paid/commit/9fb851c733033e0e32b240e5e5c0e177635bb069))
* **agent-runs:** exclude .yarn-cache/ from agent commits ([c2bad59](https://github.com/viamin/paid/commit/c2bad597933de6c655437b74eb8d9b56c257e869))
* **agent-runs:** exclude .yarn-cache/ from agent commits ([60eeed8](https://github.com/viamin/paid/commit/60eeed8dcca5fdf387cda1da9112a88dba17b2ed))
* **agent-runs:** pass pr_numbers_with_active_auto_continue as local to fix Turbo broadcasts ([8ffb56b](https://github.com/viamin/paid/commit/8ffb56b4eec7003ed91e7bf1a52d240e56ac7178))
* **agent-runs:** preserve timeout status on provider fallback ([53fa2de](https://github.com/viamin/paid/commit/53fa2de16bbc387cdb6318a650efa6f910ffd049))
* **agent-runs:** preserve timeout status on provider fallback ([e86c10d](https://github.com/viamin/paid/commit/e86c10d09e86dcda186a0260e76a345a4791bba1))
* **agent-runs:** rename active_auto_continue to queued_auto_continue for naming consistency ([83f2329](https://github.com/viamin/paid/commit/83f232980339e993fd84954919e94a95bec94da1))
* **agent-runs:** separate comments for corepack and yarn-cache excludes ([1b70eed](https://github.com/viamin/paid/commit/1b70eedfb3299357795227c1d9b24fa93d98e1ba))
* **agent-runs:** use factory create in queue_priority specs ([4bf7595](https://github.com/viamin/paid/commit/4bf759563313c4297d2188f501df9774b1f31e4d))
* **auto-merge:** address PR review feedback ([8a789a3](https://github.com/viamin/paid/commit/8a789a35f34c8210b466b033f674492afa23166b))
* **auto-merge:** allow self-authored owner PRs ([3fd15ac](https://github.com/viamin/paid/commit/3fd15acf423ec9c27224c25ec8411e14fe881615))
* **auto-merge:** allow self-authored owner PRs ([87ff690](https://github.com/viamin/paid/commit/87ff690c5ea7ad6dfc136d131671940f466b4974))
* **auto-merge:** assert toggle endpoint in owner auto-merge tests ([829b629](https://github.com/viamin/paid/commit/829b6297076110dc1cef20e7d85395d468171588))
* **auto-merge:** gate merge on auto_merge_enabled flag and add view tests ([69998bf](https://github.com/viamin/paid/commit/69998bf6878f07e5ba6e13cd8c6a77f81bc1d386))
* **auto-merge:** scope auto-merge badge assertions to Auto-Merge section ([6ff80b3](https://github.com/viamin/paid/commit/6ff80b37968e78cd9de2887d7bdd6049a67813ba))
* **auto-pick:** address PR review feedback ([b1a4762](https://github.com/viamin/paid/commit/b1a4762e1da3e69be9870df5ff4acc694093ff19))
* **auto-pick:** balance idle capacity across projects ([32fcce4](https://github.com/viamin/paid/commit/32fcce463ca7cdb74afbb978f4c1b3fa4f940da3))
* **auto-pick:** balance idle capacity across projects ([eb2cd08](https://github.com/viamin/paid/commit/eb2cd08825fd48163824971684269d59cfbcd2e0))
* **auto-pick:** memoize project ordering and collapse aggregate queries ([35afcbd](https://github.com/viamin/paid/commit/35afcbde65b352fb07b1494ef48d00b2b08f04f7))
* **dependencies:** update agent-harness to version 0.5.2 and brace-expansion to version 5.0.5 ([b71601a](https://github.com/viamin/paid/commit/b71601ac61d7fe5d501f60483f75c955c55c930c))
* **dependencies:** update agent-harness to version 0.5.2 and brace-expansion to version 5.0.5 ([7a678d3](https://github.com/viamin/paid/commit/7a678d3af9c52868a3ed749ef763b8531a7c7e24))
* **github:** avoid nil commit_message in PR merges ([afacfbc](https://github.com/viamin/paid/commit/afacfbc4393db2b13213131ee6d2407ee635d90b))
* **github:** avoid nil commit_message in PR merges ([c7efcc2](https://github.com/viamin/paid/commit/c7efcc22f9483b9405a64e0200d18f15fd80eda0))
* **hooks:** make file count threshold configurable via env var ([12221dd](https://github.com/viamin/paid/commit/12221dd9e20d0db86858571659407bdc6e34ddd3))
* **model-selection:** address code review feedback on meta-agent selector ([f1afb93](https://github.com/viamin/paid/commit/f1afb933a6d9309b558d6a65f0491774fadf8dc2))
* **model-selection:** respect preference list ordering and use realistic model IDs in tests ([225b2f7](https://github.com/viamin/paid/commit/225b2f7874a9d1d7ea9e83a0fdc4188e1ac2cdd5))
* **model-selection:** robust JSON extraction and TypeError handling in meta-agent ([ae75c08](https://github.com/viamin/paid/commit/ae75c0804c561ae38d205488183aba0d47109f17))
* **projects:** address PR review feedback on repository selector ([095213a](https://github.com/viamin/paid/commit/095213a496b23fbec25bf8b82e4a9583e6444f54))
* **projects:** address review feedback on repository selector ([8f098b6](https://github.com/viamin/paid/commit/8f098b65aba3664aed07eeda4c0dcec1115ef9bf))
* **projects:** fix regex in disabled select spec to handle &gt; in attributes ([e25a432](https://github.com/viamin/paid/commit/e25a432b27c3c249cb18dbadc5fca260c0761754))
* **projects:** show project dropdown as disabled instead of hidden before token selection ([07a5d06](https://github.com/viamin/paid/commit/07a5d06d49a0606e18a64e75407129e9b17ff40a)), closes [#359](https://github.com/viamin/paid/issues/359)
* **providers:** address PR review feedback for Gemini support ([90f34ae](https://github.com/viamin/paid/commit/90f34ae05b19d0d14f4a444441eee2d723794fb0))
* **secrets-proxy:** preserve query strings and track Google usage metadata ([7b78b94](https://github.com/viamin/paid/commit/7b78b9493b4103436e89e88e0d4b40f1a7794089))
* **ui:** address code review feedback for local_time helper ([86d6675](https://github.com/viamin/paid/commit/86d6675c252afc4e6842875fbcf605bb4e51b581))
* **ui:** address JS code review feedback for local_time_controller ([c742b79](https://github.com/viamin/paid/commit/c742b7956830856ed400bb7547c66868bb4de287))
* **ui:** handle future timestamps in relative time fallback ([c2814c7](https://github.com/viamin/paid/commit/c2814c72187669e310c89139114b43bbc15d2ce7))
* **ui:** normalize format once in local_time to keep JS/non-JS consistent ([0100010](https://github.com/viamin/paid/commit/0100010b0bd6f6e6d291d0ed43daa7fc4fc8b231))
* **ui:** use 24-hour time format and cache RelativeTimeFormat instance ([bb5de08](https://github.com/viamin/paid/commit/bb5de08921fedbfaa11fbc732d47494ed8997bb3))
* **ui:** use seconds unit for sub-minute relative times ([71c3662](https://github.com/viamin/paid/commit/71c36622c81ce0dff95feda12c3ecda5bfeee5e2))

## [0.7.0](https://github.com/viamin/paid/compare/v0.6.1...v0.7.0) (2026-03-24)


### Features

* add dependency update script ([2b1ab33](https://github.com/viamin/paid/commit/2b1ab334ebb63a68fa2ddd5b473fb97a6e8db1e6))
* add dependency update script ([5430163](https://github.com/viamin/paid/commit/54301637fd7042d49cdfb5ac561c4a1f9ae711b8))
* **auto-pick:** limit to one queued run per project and prioritize PR completion ([f255449](https://github.com/viamin/paid/commit/f2554497318be930e6303e6ecd2a3fc533403a47)), closes [#425](https://github.com/viamin/paid/issues/425)
* **cost-tracking:** add per-project cost dashboard and budget management UI ([af6f135](https://github.com/viamin/paid/commit/af6f135cd97b3c378d1a7ef792379f58fcb19972)), closes [#142](https://github.com/viamin/paid/issues/142)


### Bug Fixes

* **agent-execution:** address PR review feedback for label recovery job ([bf9ecf1](https://github.com/viamin/paid/commit/bf9ecf123ed13b9c7b18e463d406495ffe5c0b85))
* **agent-execution:** batch PR lookups and skip unsynced PRs in label recovery ([4b35898](https://github.com/viamin/paid/commit/4b358987fc00f6c35eeb5e323b018573b3a4bdcd))
* **agent-execution:** recover missing paid-generated PR labels ([761f74e](https://github.com/viamin/paid/commit/761f74e32fe0eb5b4f3c3c2326728256e1ae0b4f))
* **agent-execution:** recover missing paid-generated PR labels ([4ac386d](https://github.com/viamin/paid/commit/4ac386d33bf58b3afc82b792c75f7a908ca0771f))
* **agent-execution:** resolve Brakeman SQL injection warning and address review feedback ([daa0c69](https://github.com/viamin/paid/commit/daa0c69d517ba53baae57f38cad877f90427bc98))
* **agent-execution:** use bounded chunked queries in PR label recovery prefetch ([bf85cca](https://github.com/viamin/paid/commit/bf85ccafe241dbfcb1a433c012ec2dd32d0c09cf))
* **agent-execution:** use completion time and composite keys in label recovery ([9da715a](https://github.com/viamin/paid/commit/9da715afb99580a3e31a6454271f1aced2abc0df))
* **agent-image:** pin codex to a published version ([cd720f2](https://github.com/viamin/paid/commit/cd720f218ec90b1fe1b0e82733f18e3e5188e5b4))
* **agent-image:** pin codex to a published version ([25065ce](https://github.com/viamin/paid/commit/25065ceb6965f02da5ae8333b77497880b9d523d))
* **agent-runs:** allow auto-pick after paid-ready handoff ([d8530f4](https://github.com/viamin/paid/commit/d8530f408abfc555c7419e1325f9bd127bcf0e50))
* **agent-runs:** allow auto-pick after paid-ready handoff ([37b64b5](https://github.com/viamin/paid/commit/37b64b5cb8034b5ca722bba072f83ead79e01e56))
* **agent-runs:** combine label containment predicates into single query ([77fc7a2](https://github.com/viamin/paid/commit/77fc7a27f730800250cb290f95a7d9e6d6d33ed2))
* **agent-runs:** correct comment about query count in PR attention check ([18f590a](https://github.com/viamin/paid/commit/18f590a8e63f09df5f06e6ec8224264a0c3c78ea))
* **agent-runs:** push PR-attention check into SQL exists? queries ([2fef151](https://github.com/viamin/paid/commit/2fef1511921484188f2031d03ad1c89126b9ccf9))
* **auto-pick:** address review feedback and fix test failures ([8d2a6ee](https://github.com/viamin/paid/commit/8d2a6ee2f05c389bebe6582efaf964a72d0e89f3))
* **cost-tracking:** address code review feedback and fix CI failures ([44f576f](https://github.com/viamin/paid/commit/44f576f620c991466766f18a7ae5152426be1ca3))
* **cost-tracking:** address PR review feedback for cost dashboard ([528c116](https://github.com/viamin/paid/commit/528c1168d04715bc932d758897a6f3551df52615))
* **cost-tracking:** address remaining PR review feedback ([cf5856f](https://github.com/viamin/paid/commit/cf5856fbb895040cf849ae2ec9324a3065d1e19d))
* **cost-tracking:** address review feedback on budgets, chart empty state, and specs ([dcd0524](https://github.com/viamin/paid/commit/dcd0524eecc33bd1c791ca657dd84827a3f955ba))
* **cost-tracking:** normalize daily_costs to full 30-day range with zero-filled gaps ([11ab4d9](https://github.com/viamin/paid/commit/11ab4d99112eb035cf9517592d52378c8a387b32))
* **cost-tracking:** preserve user input on validation failure in budget forms ([982f3a3](https://github.com/viamin/paid/commit/982f3a3d4ed80d3b3307c0e048d391e477f67efc))
* **cost-tracking:** remove duplicate error on non-numeric limit_dollars ([65b2194](https://github.com/viamin/paid/commit/65b2194f9ce47444570ef9ae5112b1ffa2350f57))
* **cost-tracking:** render per_run budgets without misleading usage stats ([00ace07](https://github.com/viamin/paid/commit/00ace07a0de1b92a009107c3ba3c048f1dcbb848))
* **cost-tracking:** validate limit_dollars directly so errors show on correct field ([412fb44](https://github.com/viamin/paid/commit/412fb44b0e0516ba6470c62876c41d05d2aea093))

## [0.6.1](https://github.com/viamin/paid/compare/v0.6.0...v0.6.1) (2026-03-22)


### Bug Fixes

* **agent-execution:** cap blocking_issues log output to prevent large log lines ([4e1e6a2](https://github.com/viamin/paid/commit/4e1e6a2b05928050eb58af18afe819f3ab44de32))
* **agent-execution:** check issue dependencies before triggering agent work ([a29eccd](https://github.com/viamin/paid/commit/a29eccd7fc9dba5d34cd1c2732b2ef80b2e7c6b7))
* **agent-execution:** check issue dependencies before triggering agent work ([e01f476](https://github.com/viamin/paid/commit/e01f4769022ebeea5fdb424fc7a6ba3b867d488f))
* **agent-execution:** check labels before dependencies to avoid unnecessary queries ([eebb03f](https://github.com/viamin/paid/commit/eebb03f8661961fa58a0fc8dbc42cf5591564c09))
* **agent-execution:** clarify intentional label-before-dependency ordering ([ceb7ffa](https://github.com/viamin/paid/commit/ceb7ffa3ef36740cee0b3d1168c81c833739afec))
* **agent-execution:** limit blocking_issues query and fix README docs ([f5342b9](https://github.com/viamin/paid/commit/f5342b9190433daeaf3181c6f04969b96190a401))
* **agent-execution:** reduce blocking_issues queries by plucking first ([4cd588a](https://github.com/viamin/paid/commit/4cd588a9e7017bbfb482261aaf21e6057fd752b2))
* **providers:** address PR review feedback for addable boundary ([da48dbe](https://github.com/viamin/paid/commit/da48dbeed93750ee7d710ba0d1113c50739987c6))
* **providers:** block enabling flags on unsupported providers during update ([0e8504d](https://github.com/viamin/paid/commit/0e8504deeadefe5c3a8f66f0ae923a297a5559c4))
* **providers:** deduplicate provider_key error for unsupported keys ([45880c5](https://github.com/viamin/paid/commit/45880c5a1206cf73e3b21e53669c6ab9f500b57b))
* **providers:** improve unsupported provider validation message and test coverage ([7937450](https://github.com/viamin/paid/commit/7937450de8089841eb1ef7fd135f686873aba957))
* **providers:** only offer paid-agent-ready providers ([e51c74d](https://github.com/viamin/paid/commit/e51c74dc3684f88cc405613c6c01f575ff50f101))
* **providers:** only offer paid-agent-ready providers ([5f34cb9](https://github.com/viamin/paid/commit/5f34cb95b0e29ab7332e37b64dd7fce72a840d2f))
* **providers:** remove accidentally committed PostgreSQL build artifacts ([6e103e5](https://github.com/viamin/paid/commit/6e103e5ec2ed71ac453dd6433e13dd78acb2fb28))
* **providers:** remove build artifacts and use higher-level addable boundary check ([c6dd7b1](https://github.com/viamin/paid/commit/c6dd7b1bcb5724a644b96d14448a3e8472ef6306))
* **providers:** remove re-added PostgreSQL build artifacts ([a73471d](https://github.com/viamin/paid/commit/a73471d9bbb8017bd664f3cf5aa7598e5aaa2e41))
* **providers:** remove unused container_executable_provider_key? stubs from create specs ([c360905](https://github.com/viamin/paid/commit/c360905e55ca8656b538a5756d5cdbe9b589137a))
* **providers:** skip container-executable check for unsupported keys ([009f4ff](https://github.com/viamin/paid/commit/009f4ffd434c1415235f0dde772e0c67c5a36ef4))
* **providers:** skip inclusion validation when provider_key is blank ([c995cb2](https://github.com/viamin/paid/commit/c995cb255c1263bfc3ee9d54651e8661bce33a26))

## [0.6.0](https://github.com/viamin/paid/compare/v0.5.1...v0.6.0) (2026-03-22)


### Features

* **providers:** add Test Agent button to verify provider connectivity ([288203b](https://github.com/viamin/paid/commit/288203ba624e76c7151189deac1043959d34d78d)), closes [#385](https://github.com/viamin/paid/issues/385)


### Bug Fixes

* **containers:** align timeout precedence and log timeouts in Docker error path ([0500c0c](https://github.com/viamin/paid/commit/0500c0c37b07370549211e474b272457d4f00795))
* **containers:** bound exec stub sleep loops in watchdog specs ([fb69eea](https://github.com/viamin/paid/commit/fb69eea48f8a676d947ce1508e6ca9e8fe0a56b7))
* **containers:** clarify mutex comment on timeout_reason_ref lambda ([de66734](https://github.com/viamin/paid/commit/de667349dd6636ab29bb7ff1fd3ee916f664e31b))
* **containers:** enforce wall clock exec timeouts via watchdog ([0a9d128](https://github.com/viamin/paid/commit/0a9d1283d5c3767564c1f73d5a6d8efd63409983))
* **containers:** enforce wall clock exec timeouts via watchdog ([f761881](https://github.com/viamin/paid/commit/f761881f002d178225d115e740b0efb3f766c7d5))
* **containers:** extract WatchdogContext struct and add deadline check in Docker error path ([422085d](https://github.com/viamin/paid/commit/422085d3138cd06088005847d947eb70bcbb7a73))
* **containers:** log partial output on wall-clock timeout and add post-exec deadline spec ([fd01510](https://github.com/viamin/paid/commit/fd0151062394c44fe10285b58bb7f6d690a25cc8))
* **containers:** log startup/idle timeouts from post-exec deadline check in Docker error path ([1bf9b07](https://github.com/viamin/paid/commit/1bf9b0702a53532df9ae5dee3ddfbb3d92da6a70))
* **containers:** reduce timeout-check method params via TimeoutCheckState struct ([51db6aa](https://github.com/viamin/paid/commit/51db6aa889316e113fe5cea4a0927c33457fe2da))
* **containers:** remove redundant exec_result init and standardize wall-clock spelling ([20a7cf2](https://github.com/viamin/paid/commit/20a7cf21e0559ae80bcd59cb21dd61691be48a14))
* **containers:** update outdated timeout_reason comment and misleading spec description ([52e6e02](https://github.com/viamin/paid/commit/52e6e02f351e859cf0a09d3e4a5d1bf1d427d19d))
* **providers:** add aria-hidden and focusable attrs to decorative SVG icons in test agent ([7699193](https://github.com/viamin/paid/commit/7699193e36e698a5b658556d5f9d5143cd038336))
* **providers:** add installation error type and disconnect guards for test agent ([f25f928](https://github.com/viamin/paid/commit/f25f9284b78da2886c122810b67134c76340c1da))
* **providers:** add per-provider rate limit to test_agent endpoint ([dd4df0c](https://github.com/viamin/paid/commit/dd4df0c4f069c428f979363aba378bef5cdbcbc9))
* **providers:** address test agent review comments ([d2393af](https://github.com/viamin/paid/commit/d2393afd3475642227e5e0733118365424adb3d1))
* **providers:** address test agent review feedback and fix CI failures ([229ce95](https://github.com/viamin/paid/commit/229ce95bc75deff2cc18f9e721d97a87bad142a3))
* **providers:** move auth error shim to initializer and improve non-JSON response handling ([91da3de](https://github.com/viamin/paid/commit/91da3de0a6bc7ba6617dca75f933c7d36b8aabc3))
* **providers:** stub ProviderSupport in test_agent specs and add ARIA roles for screen readers ([3083e7c](https://github.com/viamin/paid/commit/3083e7c9624e3aca0f6d9221651710029c09ea27))
* **providers:** stub Rails.cache in rate-limit spec and add ARIA live region to loading state ([e0ec0bc](https://github.com/viamin/paid/commit/e0ec0bc790072942e163addf0f8bdd19c3b0a770))
* **providers:** use atomic cache write for test_agent rate limiting ([bff665e](https://github.com/viamin/paid/commit/bff665e742ce775a3c6300dbe0aafc8f489bbbf9))
* **providers:** use exact match for ping output and fix unsupported provider error type ([c6fcd2a](https://github.com/viamin/paid/commit/c6fcd2a9a7bb7e79ee7e6df401331e9b7b35eb84))
* **providers:** use presence check for error fallback and handle 401/403/404 explicitly ([7011f97](https://github.com/viamin/paid/commit/7011f97f8c33a492889a7257bcddbbf9002e2680))
* **providers:** validate container-executable status in test agent ([c2fdb95](https://github.com/viamin/paid/commit/c2fdb95e21aa3b4a0101be16f090ad6e0534bd56))

## [0.5.1](https://github.com/viamin/paid/compare/v0.5.0...v0.5.1) (2026-03-22)


### Bug Fixes

* **phase2:** eliminate double-lock, fix lint score, add cache invalidation ([0725749](https://github.com/viamin/paid/commit/0725749ccdcce6d063504c7657304b28beba0c55))
* **pr-review:** address code review feedback ([20fd882](https://github.com/viamin/paid/commit/20fd882ef906482edf8161f09854d6932fde44b4))
* **pr-review:** address round 4 review feedback ([c62f63b](https://github.com/viamin/paid/commit/c62f63bbb0d12f3985482103cb4648bd591d9b15))
* **pr-review:** decouple GithubClient spec from activity constant ([4f205ff](https://github.com/viamin/paid/commit/4f205ff134d05de9ba6ee662a0d4aff50f7c6fe8))
* **pr-review:** handle bot 422 separately, extract node ID constant ([d456f2d](https://github.com/viamin/paid/commit/d456f2d158de52fa73035a83048170740ca90cdb))
* **pr-review:** surface GraphQL errors from PR node ID lookup ([9714185](https://github.com/viamin/paid/commit/971418518e454c5c276af2f4c4e4f3aceae16233))
* **pr-review:** use GraphQL botIds for Copilot review re-requests ([2477ea6](https://github.com/viamin/paid/commit/2477ea6dbf8d2f7c5910b58d14ac9cfae54ed199))
* **pr-review:** use GraphQL botIds for Copilot review re-requests ([459f2e5](https://github.com/viamin/paid/commit/459f2e54404d2e5742e0f6657cee317b9147a8bf))
* **pr-review:** use GraphQL botIds for Copilot review re-requests ([ae56417](https://github.com/viamin/paid/commit/ae56417b595948a69e0e887b1f95ac1f7f7d638d))

## [0.5.0](https://github.com/viamin/paid/compare/v0.4.1...v0.5.0) (2026-03-22)


### Features

* **ab-testing:** add A/B testing management UI ([#144](https://github.com/viamin/paid/issues/144)) ([d0cf8c4](https://github.com/viamin/paid/commit/d0cf8c490cd957d1e6f099c2641d416ba47f3101))
* **agent-runs:** add PR Code Review goal type for agent runs ([e08e2e0](https://github.com/viamin/paid/commit/e08e2e0312e55bc42be82a4239238801df267366))
* **agent-runs:** prioritize create_issue runs over create_pr at same priority level ([4c9f3e0](https://github.com/viamin/paid/commit/4c9f3e0ade9f060a22a1325d694f607a5ce6d6aa)), closes [#362](https://github.com/viamin/paid/issues/362)
* **observability:** add agent run phase timings ([dac5e44](https://github.com/viamin/paid/commit/dac5e44a62a059b4169e2b2547deece2a3009797))
* **observability:** add agent run phase timings ([264e044](https://github.com/viamin/paid/commit/264e0440fc427e061501425d7a904977d2ee97fc))
* **projects:** auto-detect service dependencies from repository files ([b745d76](https://github.com/viamin/paid/commit/b745d769a427066c0594f9a8cbb9bd5a0e89376e)), closes [#247](https://github.com/viamin/paid/issues/247)


### Bug Fixes

* **ab-testing:** address PR review feedback for A/B testing UI ([0b45705](https://github.com/viamin/paid/commit/0b45705182c55af12515c8456d8bb608675fe308))
* **ab-testing:** address PR review feedback for authorization and view improvements ([3ce2a13](https://github.com/viamin/paid/commit/3ce2a13f6ae3d72255e47ba6627cbbc0b9f63ed7))
* **ab-testing:** address remaining review feedback for caching, input validation, and specs ([35665c9](https://github.com/viamin/paid/commit/35665c949bac0a40477a704ae769b28014667679))
* **ab-testing:** address review feedback for input validation and cache efficiency ([1b8263e](https://github.com/viamin/paid/commit/1b8263e73135327d8a7fa613c666c3544ec5dc44))
* **ab-testing:** address review feedback for nil score handling and analysis performance ([a0b7dad](https://github.com/viamin/paid/commit/a0b7dad0aa818ad2d6ebf74d8c9eca09d359b09a))
* **ab-testing:** cache analysis results to avoid expensive per-request score aggregation ([88b8bc9](https://github.com/viamin/paid/commit/88b8bc9f05f1a4d5b23a4f7a89a3a2ead3ea1571))
* **ab-testing:** compute analysis for completed tests on cache miss ([70b67e4](https://github.com/viamin/paid/commit/70b67e4f64c76b76ecaaca6d3021e6da022b1251))
* **ab-testing:** fix test failure, harden input parsing, and add cross-account specs ([72eded1](https://github.com/viamin/paid/commit/72eded1b3e93a915241e0d8bd00b68ef9693f29b))
* **ab-testing:** harden promote action, avoid extra query in cache key, and add missing spec ([eb5fd45](https://github.com/viamin/paid/commit/eb5fd453472383cf27c03120a4b4915ae9147556))
* **ab-testing:** improve error messages and remove unused spec variables ([d684509](https://github.com/viamin/paid/commit/d6845094ef9fbfc097800709d3511f70e47e8ea4))
* **ab-testing:** include total sample bucket in cache key ([e874f8a](https://github.com/viamin/paid/commit/e874f8a37d57e330e3b0eb3ed7d4a015d3bf8208))
* **ab-testing:** make index? consistent with account scope and keep GET read-only ([6c2d098](https://github.com/viamin/paid/commit/6c2d0983546661c7a3dcce1a5ce21377627d8c79))
* **ab-testing:** remove unrelated schema changes not backed by migrations ([378fa6e](https://github.com/viamin/paid/commit/378fa6e18e4f0df3e00eebcd4b852639d3d72760))
* **ab-testing:** resolve merge conflicts and address review feedback ([cd5ed4d](https://github.com/viamin/paid/commit/cd5ed4dcdfb461ddf12ecabbc7cb3dbe8f0bd7f3))
* **ab-testing:** show analysis for completed tests and fix SVG viewBox ([9dcd8c5](https://github.com/viamin/paid/commit/9dcd8c5cc9dd729ac4c22e957c2d621d1eec8b85))
* **ab-testing:** surface service validation errors and remove unrelated changes ([86fc639](https://github.com/viamin/paid/commit/86fc639f7dc37435ab7bb2ff3c9eab99c6b82595))
* **agent-runs:** address final review feedback on PR code review goal ([e36ff2f](https://github.com/viamin/paid/commit/e36ff2f6766fc667a204e8e0de223b55a01bdfe3))
* **agent-runs:** address PR review feedback on review goal prompt and completion ([e737d97](https://github.com/viamin/paid/commit/e737d9789b71769755adc440f4ddc10748738711))
* **agent-runs:** address remaining PR review feedback on review goal ([4209a9f](https://github.com/viamin/paid/commit/4209a9fb002d2c4ffdd239dcf986e228d876cffa))
* **agent-runs:** address review feedback for PR code review goal ([eb8fd90](https://github.com/viamin/paid/commit/eb8fd90454e9febf20155c8c65c084330d771144))
* **agent-runs:** fail review goal when no review posted and validate PR number in proxy ([1eb2248](https://github.com/viamin/paid/commit/1eb2248c584f9f11f0698b9953870717a3fc247f))
* **agent-runs:** guard review tracking by goal type and prevent retries on deterministic failures ([5f05397](https://github.com/viamin/paid/commit/5f0539760d5450e7b422829ce5533a0c7aa4f085))
* **agent-runs:** hide agent, tokens, and cost columns from agent runs tables ([972cf08](https://github.com/viamin/paid/commit/972cf08c7ed2f2d69aecd3952a0b061e2e79c27e)), closes [#393](https://github.com/viamin/paid/issues/393)
* **agent-runs:** make review_posted_at tracking idempotent ([6f0fcfd](https://github.com/viamin/paid/commit/6f0fcfd50c64f5d0e45038764fdac3f6535be35f))
* **agent-runs:** merge main, fix review prompt diff instructions, add validation spec ([9b324bf](https://github.com/viamin/paid/commit/9b324bf1393b402f2a0cda82d770ae0e032cffcc))
* **agent-runs:** preserve goal selection across form redirects and remove redundant reload ([4ff3e6a](https://github.com/viamin/paid/commit/4ff3e6ab504294b2abd9c6f35c28f2c0b236da97))
* **agent-runs:** track review creation in proxy and verify in completion activity ([d2fce4f](https://github.com/viamin/paid/commit/d2fce4f3ac28400745e0da4e6794a2f7e9076839))
* **agent-runs:** update redirect specs to include goal param after merge ([e1abd23](https://github.com/viamin/paid/commit/e1abd2347fd7ca4a9cb6a8cb805993749d5e3103))
* **agent-runs:** update specs to match removed agent column from tables ([2ee6055](https://github.com/viamin/paid/commit/2ee605564bd04fb9b56371c7a4e858788233abba))
* **agent-runs:** wrap CompleteReviewGoalActivity in track_phase for observability ([b2445a1](https://github.com/viamin/paid/commit/b2445a1209b4fc11e3a1dea2a3c1cd20a3f1e2cc))
* **cost-tracking:** address review feedback on Check docs and nil safety ([00a0cfe](https://github.com/viamin/paid/commit/00a0cfefb24bd4613bd8df12d4d467b2c9a1df88))
* **devcontainer:** address PR review feedback for enable-commit-signing.sh ([c3ce679](https://github.com/viamin/paid/commit/c3ce6795feb8bb7e8e828293b82c19aea5be1dc0))
* **devcontainer:** address PR review feedback for signing scripts ([ec61ecb](https://github.com/viamin/paid/commit/ec61ecb36947507e1c75460b32fd7f568fbcdbe6))
* **devcontainer:** address remaining PR review feedback ([05f5af7](https://github.com/viamin/paid/commit/05f5af7f0791bd9f5d7296942907e50bbd317b0e))
* **devcontainer:** avoid capturing full API response and narrow 403 matching ([fbaf1ee](https://github.com/viamin/paid/commit/fbaf1eee444bde04789cd129890b9262510b7274))
* **devcontainer:** distinguish scope errors from general API failures ([9c8fb37](https://github.com/viamin/paid/commit/9c8fb372c3937eb5fd15fec8d0801a0972d5f593))
* **devcontainer:** fix stderr/stdout redirection in scope check ([e18ed86](https://github.com/viamin/paid/commit/e18ed8619a7b990bb11112e9e8f9997448186612))
* **devcontainer:** gracefully handle missing gh auth in signing setup ([39a8f2e](https://github.com/viamin/paid/commit/39a8f2e6d60c3f8aa055744a4845f4b0d2ca895b))
* **devcontainer:** gracefully handle missing gh auth in signing setup ([3c3eb52](https://github.com/viamin/paid/commit/3c3eb52effddf4ed797849ed55354a8b4592f222))
* **devcontainer:** remove accidentally committed .bundle-install build artifacts ([ff78a33](https://github.com/viamin/paid/commit/ff78a33ed42b980309642235706a9fe2aff4d067))
* **devcontainer:** use BASH_SOURCE for reliable script path resolution ([1fa00a1](https://github.com/viamin/paid/commit/1fa00a1a178e040ec3a6f0ffa2a8ad2e12aa5d20))
* **devcontainer:** use consistent "Dev Container" terminology in README heading ([c0f3b9b](https://github.com/viamin/paid/commit/c0f3b9b195b937ebfe0e3d9959cfa03f4e391077))
* **devcontainer:** use explicit github.com host for gh auth status checks ([8b92e76](https://github.com/viamin/paid/commit/8b92e7679bd9e6a752a688ea2720d08ba689a9b1))
* **devcontainer:** use repo root for git config validation in enable-commit-signing ([f6bce74](https://github.com/viamin/paid/commit/f6bce7406181d1eed52ac170a75d7b045d318209))
* **devcontainer:** verify signing key file exists before reporting success ([cf253ff](https://github.com/viamin/paid/commit/cf253ff2f51764dffb86fe1518d587121d742196))
* **issues:** use high github_numbers in parse_dependencies specs to avoid sequence collisions ([9a1d257](https://github.com/viamin/paid/commit/9a1d257a760f99af6caa30ee2f432975222b6928))
* **observability:** address review feedback ([ad7c4c7](https://github.com/viamin/paid/commit/ad7c4c798be900a0168f2fb695b15d636e4357b4))
* **observability:** align create-run phase start time ([78596e6](https://github.com/viamin/paid/commit/78596e6b865a357ee3ad200c5a17f0f80431c369))
* **observability:** handle rollout gaps in phase metrics ([14faa3f](https://github.com/viamin/paid/commit/14faa3f60e8ce2736889a03926c9f8493ddb76e2))
* **observability:** harden phase breakdown reporting ([a1dc10a](https://github.com/viamin/paid/commit/a1dc10af01052b83717f5bc9b4bbd5ed9b78ac31))
* **observability:** tighten phase tracking followups ([24468d1](https://github.com/viamin/paid/commit/24468d17aadcd0f68b53b193f9e32e4a38b59f5b))
* **observability:** tighten run timeline rendering ([0c9179b](https://github.com/viamin/paid/commit/0c9179bb67e0712f0d1d40858762be83f23c6b0d))
* **observability:** wire phase data through project show ([2538762](https://github.com/viamin/paid/commit/2538762020dc4cd5c8f9278a6841397039a6dc96))
* **pr-review:** block draft exit on missing bot review state ([bd6e390](https://github.com/viamin/paid/commit/bd6e39090a997ba0b19efa9fc424b98d8669512c))
* **pr-review:** require clean bot review before draft exit ([2f67a9a](https://github.com/viamin/paid/commit/2f67a9a5424dab1b557365b2a7d2ac65d0981add))
* **pr-review:** require clean bot review before draft exit ([665b398](https://github.com/viamin/paid/commit/665b398a8d302c4db6ef27d97d48d33d16c388ba))
* **pr-scanner:** avoid agent update loops and refresh copilot review ([6ba7659](https://github.com/viamin/paid/commit/6ba7659ee4afe83b6978feb40a6b3d760328a46b))
* **pr-scanner:** avoid agent update loops and refresh copilot review ([40a443b](https://github.com/viamin/paid/commit/40a443b06b8ebeb5b27f8a2481e309951a9538a6))
* **pr-scanner:** ensure Copilot review is requested after agent fixes comments ([7cc9635](https://github.com/viamin/paid/commit/7cc9635d1321cb2fbe653f39ad556423c78e3f34))
* **pr-scanner:** ensure Copilot review is requested after agent fixes comments ([f88e7e9](https://github.com/viamin/paid/commit/f88e7e927b334a45e5159290c517f785ecbe2497))
* **pr-scanner:** share agent update comment marker ([36e654b](https://github.com/viamin/paid/commit/36e654bde87cbcc7e46b793343ba401495f669d6))
* **projects:** add missing require "base64" to detect_services spec ([2318d9a](https://github.com/viamin/paid/commit/2318d9ac3828e8690a5c1694817d777ba55de8b3))
* **projects:** address code review feedback for detect_services ([a0b537a](https://github.com/viamin/paid/commit/a0b537a4000bd60534f932ffbc8125d46edbaec3))
* **projects:** address remaining review feedback for detect_services ([94b25ad](https://github.com/viamin/paid/commit/94b25add88d8bb2c58e7a1587dfee05ae8b7773f))
* **projects:** address review feedback for detect_services ([6567516](https://github.com/viamin/paid/commit/65675169bbcea61c753a7e2027a9fce80a795a7b))
* **projects:** address review feedback for detect_services ([994f824](https://github.com/viamin/paid/commit/994f824048a9f6ff22ea007776be2e2f7f51fab5))
* **projects:** handle existing service containers in detect_services specs ([b5c9e40](https://github.com/viamin/paid/commit/b5c9e40e7ba441f8eb21e3eb1b3d51274493de0d))
* **projects:** improve detect_services resilience and code organization ([ffd2922](https://github.com/viamin/paid/commit/ffd2922b0f02eb467b1a24b2edc8254a33fa6b96))
* **projects:** narrow fetch_file rescue to NotFoundError only ([b94b50f](https://github.com/viamin/paid/commit/b94b50fe7ad35e172bc39078babdbd56d7a65853))
* **projects:** use realistic Psych errors in detect_services specs ([09ff8a5](https://github.com/viamin/paid/commit/09ff8a58c9eff6533653504e327bf3c7b6a3c61e))
* **providers:** address review feedback on validation, error handling, and fallback dedup ([f51ecc8](https://github.com/viamin/paid/commit/f51ecc8718d9f37868bd3a9fefd99ed00572ff8a))
* **providers:** align app keys with harness support ([8bf1e01](https://github.com/viamin/paid/commit/8bf1e0170fd5ee950fc57a882faa36b5608ae414))
* **providers:** delegate container_executable_provider_key? to filtered method ([fecfc59](https://github.com/viamin/paid/commit/fecfc5956484ade9837c9f20adc0e71be0857456))
* **providers:** derive guardrails from dynamic default provider key ([8baf4fd](https://github.com/viamin/paid/commit/8baf4fdf6ce16fa9050a8545434c0d0a4b4ef96a))
* **providers:** gate agent runs/fallback to container-executable providers ([802e86f](https://github.com/viamin/paid/commit/802e86f3df2def843f6e800fbe7cedd514b3215c))
* **providers:** gate container execution to installed CLIs only ([81b4bd3](https://github.com/viamin/paid/commit/81b4bd3ac08fc995f23d565bb76a19ba377503e9))
* **providers:** make default_provider dynamic and memoize supported keys ([28b73d7](https://github.com/viamin/paid/commit/28b73d7d4b9f22794933f4c8b215c9d9129a17b3))
* **providers:** source supported providers from agent harness ([5f78ce3](https://github.com/viamin/paid/commit/5f78ce3a32200400036b0c53433709957f053403))
* **providers:** stub container-executable keys in agent_runs retry specs ([0676515](https://github.com/viamin/paid/commit/0676515121c66ca7ba4d6e73a720f9845adabecd))
* **providers:** tighten fallback initialization ([6e141f4](https://github.com/viamin/paid/commit/6e141f4e7af95789ba3512c58fe4d27781bea164))
* **providers:** use container-executable keys for default provider and freeze memoized set ([f8470a9](https://github.com/viamin/paid/commit/f8470a94f4927937477dad6f966f197f341fb665))
* **providers:** use dynamic default provider key in settings reconciliation ([74186a7](https://github.com/viamin/paid/commit/74186a76714642efcd3ae7e1e6919c94a5dab802))
* source supported providers from agent harness ([2c525ea](https://github.com/viamin/paid/commit/2c525ea9ce59ec2f723d16dca2b42dc55489008f))

## [0.4.1](https://github.com/viamin/paid/compare/v0.4.0...v0.4.1) (2026-03-19)


### Bug Fixes

* **pr-review:** re-request bot review after commented runs ([8707862](https://github.com/viamin/paid/commit/8707862b05b1fdcc80b279f8c559af5201fad755))
* **pr-review:** re-request bot review after commented runs ([47b2d23](https://github.com/viamin/paid/commit/47b2d23d187b3d1b87395de1d0cff381572df8f9))
* **pr-review:** remove stray schema changes ([bf7852d](https://github.com/viamin/paid/commit/bf7852d9b1aad4c94392a0a93849712ad72c10c5))

## [0.4.0](https://github.com/viamin/paid/compare/v0.3.0...v0.4.0) (2026-03-19)


### Features

* **ab-testing:** implement A/B testing framework for prompts ([#143](https://github.com/viamin/paid/issues/143)) ([7c98045](https://github.com/viamin/paid/commit/7c980452cc1fd6f6c155bfc85e5e9bfb5b327010))
* **agent-runs:** add provider retry split button ([fa5bc7c](https://github.com/viamin/paid/commit/fa5bc7c324de420fddd66aa9686bc903b72ed602))
* **agent-runs:** add provider retry split button ([923749a](https://github.com/viamin/paid/commit/923749ad3b340420c210d9cdee4c1c17a5c17a86))
* **containers:** use shallow clone to speed up repo cloning ([8d6b79d](https://github.com/viamin/paid/commit/8d6b79d0c70864e848d6febf0944e8babb161978))
* **containers:** use shallow clone to speed up repo cloning ([72bcf36](https://github.com/viamin/paid/commit/72bcf36239cdf558acb3d9db6554785879aefa05))
* **pr-scanner:** check review bot status via review body instead of threads ([b20377e](https://github.com/viamin/paid/commit/b20377e68e31951dffcbc7f56a760b165123f07f))
* **prompts:** add proactive self-review to PR followup prompt ([fbea96f](https://github.com/viamin/paid/commit/fbea96f44c66dd2c3937f035c6c28d8f4e2128af))
* **providers:** move provider priority to providers page ([2af7e68](https://github.com/viamin/paid/commit/2af7e68b78a1925646c23bf897470b4ed6642a42))
* **providers:** move provider priority to providers page ([8c0c061](https://github.com/viamin/paid/commit/8c0c0614967e9e1d449c9d383f193b6bacf5c89a))
* **quality-metrics:** add quality metrics dashboard to UI ([#146](https://github.com/viamin/paid/issues/146)) ([683ff5d](https://github.com/viamin/paid/commit/683ff5d290a2c0f6c9f4f1248d638406d8666bd8))
* **quality-metrics:** add QualityMetric model and metrics collection services ([39d1204](https://github.com/viamin/paid/commit/39d12048d3a3a24bc29242ade4be5e101cb11532)), closes [#145](https://github.com/viamin/paid/issues/145)
* **queue:** prioritize manual and auto-continue runs over auto-picked ([a8f1c03](https://github.com/viamin/paid/commit/a8f1c0373f8c531d40bbd7a0cac4165fe9081786))


### Bug Fixes

* **ab-testing:** add pessimistic locking to status transitions and guard auto-completion ([8fa0dc5](https://github.com/viamin/paid/commit/8fa0dc52c7eec5e65ed919724634a303eb690707))
* **ab-testing:** address code review comments on precision, validation, and error consistency ([15040f1](https://github.com/viamin/paid/commit/15040f154b43f3393ac5ff6f50019f09562b0aff))
* **ab-testing:** address code review feedback and fix CI failures ([63ada06](https://github.com/viamin/paid/commit/63ada061f58c246468c4eb26bcf4d9d5c33c9edd))
* **ab-testing:** address final PR review feedback ([a0b1681](https://github.com/viamin/paid/commit/a0b168137ee3958db1f7aa842318beadba239446))
* **ab-testing:** address migration review comments ([21f1001](https://github.com/viamin/paid/commit/21f1001d600fda5ecb087e8e96d6fa5614acd865))
* **ab-testing:** address PR review feedback for A/B testing framework ([5188854](https://github.com/viamin/paid/commit/5188854ec26e9903691c5e12d5005e6f2de1c270))
* **ab-testing:** address remaining code review feedback ([0d54a51](https://github.com/viamin/paid/commit/0d54a5114fd527b0adf66bd3117240af421333c0))
* **ab-testing:** address remaining PR review feedback ([92a129b](https://github.com/viamin/paid/commit/92a129b8c2fc11301cc0f29f8333e0b43506346e))
* **ab-testing:** address review comments on timestamps, throttling, and integration scope ([82d19fa](https://github.com/viamin/paid/commit/82d19fa9e2232bb40d7a659db85ea54aca95976e))
* **ab-testing:** handle zero-variance significance and unique index violation in start! ([05f650f](https://github.com/viamin/paid/commit/05f650fb004156832940d5f336b8d69011c2b368))
* **ab-testing:** merge main, address review comments ([af48a04](https://github.com/viamin/paid/commit/af48a04f176f248ce502c745feb403bdc125a78b))
* **ab-testing:** prevent race condition in RecordResult and increase score precision ([bb2d489](https://github.com/viamin/paid/commit/bb2d489d58ce98c3d995f809814904e44d58300b))
* **ab-testing:** remove .gem-cache build artifacts and add to .gitignore ([8fb8747](https://github.com/viamin/paid/commit/8fb8747e2d60927ba1b7f77c5af8e335665476a4))
* **ab-testing:** reorder Prompt associations and clarify integration scope ([d3ebfee](https://github.com/viamin/paid/commit/d3ebfeeff3df9ce456926a9be05d1bce143a5c06))
* add stringio require and use behavioral HTML compression test ([63ff5a9](https://github.com/viamin/paid/commit/63ff5a974486a77996f5b0102f40c99a4d8822dc))
* address PR review feedback for gzip compression ([263b2e8](https://github.com/viamin/paid/commit/263b2e807a39355ee536aba79ebcd8c69d3a29c7))
* address PR review feedback on Rack::Deflater ([ab4c464](https://github.com/viamin/paid/commit/ab4c4640116104beadc9e19a314f68868a1e64d8))
* **agent-runs:** derive retry provider labels from agent harness ([813d7fc](https://github.com/viamin/paid/commit/813d7fc04b08c9f22a2b4d7168822e260a4f8f4b))
* **agent-runs:** preserve primary retry provider ([b5ee75f](https://github.com/viamin/paid/commit/b5ee75f4d8009452b4cd5da045719b74345d8e33))
* **agent-runs:** simplify retry dropdown states ([5706f1f](https://github.com/viamin/paid/commit/5706f1f2e411739627dfb391a5b589104d04116b))
* **agent-runs:** tighten retry dropdown behavior ([6e35f2f](https://github.com/viamin/paid/commit/6e35f2f3e555a9254634c343e0ad69018c4a8728))
* **agent-runs:** use rev-parse HEAD for clone idempotency check ([c1a6b5b](https://github.com/viamin/paid/commit/c1a6b5b11d07ba823540979b7e22da3f70569c4d))
* **agent-runs:** use rev-parse HEAD for clone idempotency check ([379de95](https://github.com/viamin/paid/commit/379de958b1bf2b89d7bb87930d466f7f4ea076a2))
* **ci:** allow dependabot PRs in claude-code-review workflow ([667ed84](https://github.com/viamin/paid/commit/667ed84add708683dbc4b5aa230610be094a9680))
* **ci:** allow dependabot PRs in claude-code-review workflow ([eac72b7](https://github.com/viamin/paid/commit/eac72b7639738cec440146bbea34d12e9bfaffac))
* **ci:** update rebase activity spec for refspec fetch ([cae119d](https://github.com/viamin/paid/commit/cae119d680a806f1182206120daeba0186acd85b))
* **concurrency:** address third round of review feedback ([e07c33c](https://github.com/viamin/paid/commit/e07c33c4b9361a8154f5880034ba60f5cdec6da2))
* **concurrency:** bound job loop and clear orphaned owner cache ([1fc53d8](https://github.com/viamin/paid/commit/1fc53d856e44062b33886a4113bdf0b6ffb5baaa))
* **concurrency:** count orphaned-project runs and eliminate duplicate query ([baa57af](https://github.com/viamin/paid/commit/baa57af7bd1625c5f72b204938163d9be8e30b46))
* **concurrency:** deterministic owner pick and bound loop iterations ([cc7124d](https://github.com/viamin/paid/commit/cc7124d8e86ce2324d0440a134ddafbd11d2e70b))
* **concurrency:** fail closed on nil user and skip auto-pick at capacity ([09afdb8](https://github.com/viamin/paid/commit/09afdb8765de5bae271ab770f85665d5f1c01a74))
* **containers:** address PR review feedback on shallow clone ([803175c](https://github.com/viamin/paid/commit/803175c8ba5ad6693656ab7c5bb58beef5c1ca87))
* **containers:** address review feedback on timeouts and test matchers ([13d69d3](https://github.com/viamin/paid/commit/13d69d37f95b3a0485157a802440e0917c64b2ea))
* **containers:** align stale-info recovery review feedback ([f2616b7](https://github.com/viamin/paid/commit/f2616b70e0c6389c0eceeaee1ed7c442ac52ec65))
* **containers:** align stale-info retry order with lease sha ([1dbe6ae](https://github.com/viamin/paid/commit/1dbe6ae89c3909319b2069f08e57abf4949241bb))
* **containers:** check shallow status before unshallow, raise on failure ([5308bac](https://github.com/viamin/paid/commit/5308bac020e9717c99bbaaa1dbd61443bf2bdd06))
* **containers:** disambiguate error messages when fetch succeeds ([443b180](https://github.com/viamin/paid/commit/443b18082f913e40a9418ac497ee8e180b70466f))
* **containers:** fetch explicit remote refs for PR runs ([11a82b1](https://github.com/viamin/paid/commit/11a82b121cd7d4397bdc7597652610ecefd96082))
* **containers:** fetch explicit remote refs for PR runs ([3ed4207](https://github.com/viamin/paid/commit/3ed4207891df161287dcae5a3422321f222a97e0))
* **containers:** harden clone timeout config ([888d7d7](https://github.com/viamin/paid/commit/888d7d7726f495b05c9d5b4e008782b426de557f))
* **containers:** improve error context and logging in shallow clone ([8e44186](https://github.com/viamin/paid/commit/8e4418667344ed467554bb5e79abfa45f34c6341))
* **containers:** label paid workspace volumes ([8326355](https://github.com/viamin/paid/commit/8326355653b87ae21f66d9c84b7bb10d3e77c919))
* **containers:** label paid workspace volumes ([8b4475d](https://github.com/viamin/paid/commit/8b4475d96feba60a5ccc1c4c2e2da715e89e707f))
* **containers:** recover from partial clone retries ([1b38761](https://github.com/viamin/paid/commit/1b38761ce34f2d474ad4a2a700d5594d988bbf45))
* **containers:** recover from partial clone retries ([33eb556](https://github.com/viamin/paid/commit/33eb556a3b0d2054fba58c5c2dd519133eb029d3))
* **containers:** recover stale-info push rejections on PR branches ([42ee4dd](https://github.com/viamin/paid/commit/42ee4dd1e99532ec7964d040b4bc0afad9b1f9cb))
* **containers:** recover stale-info push rejections on PR branches ([6a72604](https://github.com/viamin/paid/commit/6a72604e9b7d88de6fc081745a6e1339bfd3e1ed))
* **containers:** refresh remote before stale-info rebase ([8956003](https://github.com/viamin/paid/commit/8956003ccaba2bab48bdd3f19b26286e4007708a))
* defer Rack::Deflater insertion to initializer for correct env config ([fb0189b](https://github.com/viamin/paid/commit/fb0189beef4fb897f120ad991b5f1fdbb70c1da0))
* **devcontainer:** allow tailscale hosts by default in development ([5236b83](https://github.com/viamin/paid/commit/5236b83038a81a03fffdb478ad6df5d1d230e0e5))
* **devcontainer:** allow tailscale hosts by default in development ([2095958](https://github.com/viamin/paid/commit/2095958d6b69954c0fcebb17801dec6362076a57))
* **docs:** address fourth round of PR review feedback ([ef13b13](https://github.com/viamin/paid/commit/ef13b139e2890c96999210a0f5b392c4413e47e3))
* **docs:** address PR review feedback on style guide ([b6b68f4](https://github.com/viamin/paid/commit/b6b68f4e683964305fc1515eed2500197eccd768))
* **docs:** address second round of PR review feedback ([7a3389a](https://github.com/viamin/paid/commit/7a3389a79b5055fcc34fe2c0acdd3f587a7e49b0))
* **docs:** address third round of PR review feedback ([fedf7fa](https://github.com/viamin/paid/commit/fedf7fa7c93abfc36c7060fe19956352e073ddf0))
* guard Rack::Deflater insertion and use standard header names ([cac0582](https://github.com/viamin/paid/commit/cac058228208e8d432b0850c2411f2210e02ba81))
* **pr-scanner:** address review feedback on bot review behavior ([ad0e099](https://github.com/viamin/paid/commit/ad0e099288ff35648f09d2788b3f7e800cbd5e0c))
* **pr-scanner:** block ready transition when bot review has comments ([4256a78](https://github.com/viamin/paid/commit/4256a7839d34224791f65449f5f16dbc8681e070))
* **pr-scanner:** block ready transition when bot review has comments ([c9950b5](https://github.com/viamin/paid/commit/c9950b5059629d2a86c87784925d2d4e648255a3))
* **pr-scanner:** distinguish fetch failures from empty reviews ([92d5a06](https://github.com/viamin/paid/commit/92d5a0694d3ea40dcbd6f48fc26c0cb6c08aa92d))
* **prompts:** address PR review feedback on self-review prompt ([c0a6168](https://github.com/viamin/paid/commit/c0a61680d6fdd7e113bb3c82630ed91b74255a33))
* **prompts:** move proactive scan into action steps for visibility ([e346a85](https://github.com/viamin/paid/commit/e346a85a12620265b28a66064e70a0f884b70c02))
* **prompts:** move proactive scan into action steps for visibility ([29bb540](https://github.com/viamin/paid/commit/29bb5407539c60568b4295f4c8592564806797a7))
* **prompts:** refine self-review scope and improve spec coverage ([fa48bf6](https://github.com/viamin/paid/commit/fa48bf64e07a11f69b274f9e2ebda8b02588e523))
* **providers:** align review refactors ([60415d5](https://github.com/viamin/paid/commit/60415d5da36d39b2a39dbf30def2d6932efa2f25))
* **quality-metrics:** add updated_at column and extract shared score proxy ([eee4039](https://github.com/viamin/paid/commit/eee4039ecf6cb00c0fdf02cf6428adbb7440c58f))
* **quality-metrics:** address PR review feedback ([913aa55](https://github.com/viamin/paid/commit/913aa5508c63e88c9573e96f4b531533468d680e))
* **quality-metrics:** address PR review feedback for OpenStruct, duplication, and performance ([abd27b9](https://github.com/viamin/paid/commit/abd27b9629f9e376068fde4b1efb7b36ff337ccc))
* **quality-metrics:** address PR review feedback for performance and safety ([7db13f0](https://github.com/viamin/paid/commit/7db13f0ac8755b48c19bbb83e6765b2f031d1983))
* **quality-metrics:** address PR review feedback for send bypass and merge rate denominator ([29533d2](https://github.com/viamin/paid/commit/29533d29dcfd29ad114940648400cd74747fd4d8))
* **quality-metrics:** address PR review feedback for view queries, empty scores filter, and loop efficiency ([f5458ed](https://github.com/viamin/paid/commit/f5458edbad9e5ab4bce0adf4881d953d5bbbb9ca))
* **quality-metrics:** address remaining PR review comments ([6757e2b](https://github.com/viamin/paid/commit/6757e2b7d7c2e0c84a59420257fed8d83d1060d3))
* **quality-metrics:** align spec expectation with format_quality_score output ([9a1b7ed](https://github.com/viamin/paid/commit/9a1b7ed6cfda85425bc0ec94dfe5acc9df8439e8))
* **quality-metrics:** cast SQL aggregate aliases to proper Ruby types ([0a28c2f](https://github.com/viamin/paid/commit/0a28c2fa231956f311f026d11eb222ce3d956b3f))
* **quality-metrics:** clamp iterations to minimum of 1 in automated score ([0252e07](https://github.com/viamin/paid/commit/0252e0717ee442e5bba4575086781250b364ae5b))
* **quality-metrics:** combine updated_at into original create_quality_metrics migration ([919e608](https://github.com/viamin/paid/commit/919e6089f0d8d465cd6ca7052367dea631c7a09f))
* scope compression to non-HTML types and validate gzip in specs ([d5d6365](https://github.com/viamin/paid/commit/d5d6365c2d29e249e3e22b2b6e133fd1e765600a))
* **spec:** stub unshallow in rebase_branch_activity spec ([c115939](https://github.com/viamin/paid/commit/c11593974dcc70116037c90acf51eb09130faacb))
* test actual HTML content type exclusion and verify BREACH mitigation ([6552896](https://github.com/viamin/paid/commit/6552896e03f0d483402d5e2ea852d9d8ed504f5e))
* **testing:** move RSpec status file to spec/ and gitignore it ([2629e15](https://github.com/viamin/paid/commit/2629e15425309d9209f00010baf4cda283b4381a))
* use insert_after Rack::Sendfile for reliable middleware placement ([bf04bc3](https://github.com/viamin/paid/commit/bf04bc3f78e4cd400c78d74748d8c1c9c06f283a))
* use insert_before for Rack::Deflater and add compression specs ([0e901d3](https://github.com/viamin/paid/commit/0e901d3f1935f0449396117df62bab2504c0edbf))


### Performance Improvements

* **concurrency:** memoize orphaned_project_owner? per account ([54dce8b](https://github.com/viamin/paid/commit/54dce8ba9d5423b70bae6a8e464d34c2aabba1ff))
* **concurrency:** use ID-only queries in orphaned_project_owner? ([b0b6418](https://github.com/viamin/paid/commit/b0b64185e33d568b7859ce74e29c2107736cf18c))
* **concurrency:** use instance-level capacity cache in job loop ([1a3ef4e](https://github.com/viamin/paid/commit/1a3ef4ec1183a290d9e146b81b506fce56357600))
* enable gzip compression via Rack::Deflater ([a0eb342](https://github.com/viamin/paid/commit/a0eb3421e209f1c51e14b31ce0bc4dfcdb8eed96))
* enable gzip compression via Rack::Deflater ([f795912](https://github.com/viamin/paid/commit/f795912bf721d3121bfcf7a18abf2690473ff232))

## [0.3.0](https://github.com/viamin/paid/compare/v0.2.0...v0.3.0) (2026-03-14)


### Features

* **projects:** add auto-pick toggle to projects index page ([8419837](https://github.com/viamin/paid/commit/8419837745464b2e82f30738e3d309f2cd6c315c)), closes [#323](https://github.com/viamin/paid/issues/323)


### Bug Fixes

* **ci:** add language runtime setup to CodeQL workflow ([cd86fd1](https://github.com/viamin/paid/commit/cd86fd126f8c59624243eba126bf3aa9c9044456))
* **ci:** exclude vendor directory from CodeQL scanning ([73b82ab](https://github.com/viamin/paid/commit/73b82abe933eec0d6c887d82548c91e89d52a6a6))
* **ci:** remove custom CodeQL workflow and cover index toggle behavior ([f6cd290](https://github.com/viamin/paid/commit/f6cd290c606793ba32c40b76beef371e76c1ea4c))
* **ci:** remove vendored gems from git and address review feedback ([857bd47](https://github.com/viamin/paid/commit/857bd47deefbdd589c6aa5456f57f4bebe72374d))
* **containers:** add comprehensive Docker orphan cleanup ([10d4cb6](https://github.com/viamin/paid/commit/10d4cb650394d4c42c1d336b7522be7474a321b3))
* **containers:** add comprehensive Docker orphan cleanup ([33a320f](https://github.com/viamin/paid/commit/33a320f87d45b09e3868107407db992bfc897840))
* **containers:** address PR review feedback ([7e7df7e](https://github.com/viamin/paid/commit/7e7df7ea9f946f1f0b557171677484d6c2826ed5))
* **containers:** address second round of PR review feedback ([4d96d34](https://github.com/viamin/paid/commit/4d96d3486e10e5a4ed0bdca9ef9ff76466a3a719))
* **projects:** use dedicated partial for index page auto-pick toggle ([6794fed](https://github.com/viamin/paid/commit/6794fed15b53fb8755a450756f5b7bfb0e1bacfc))

## [0.2.0](https://github.com/viamin/paid/compare/v0.1.0...v0.2.0) (2026-03-08)


### Features

* **agent-runs:** add ability to filter agent runs by goal text ([7a11a2e](https://github.com/viamin/paid/commit/7a11a2eef4bea94f853b0ab16de191647d86cab7)), closes [#306](https://github.com/viamin/paid/issues/306)
* **agent-runs:** add goal type filter and replace branch column with context info ([7fe979f](https://github.com/viamin/paid/commit/7fe979f708237ae8a40ff27405f6b26754591322)), closes [#317](https://github.com/viamin/paid/issues/317)
* **agent-runs:** auto-pick unblocked issues when agent becomes idle ([e160b70](https://github.com/viamin/paid/commit/e160b70c9bef922f80d22dcc8d4ec7ede595367f)), closes [#275](https://github.com/viamin/paid/issues/275)
* **agent-runs:** track rate limit errors and pause provider until reset ([cded10c](https://github.com/viamin/paid/commit/cded10ccc2b729a48f09f412df269eef1502a373)), closes [#291](https://github.com/viamin/paid/issues/291)
* **agent-runs:** wire per-user max_concurrent_runs into capacity checks ([8bae913](https://github.com/viamin/paid/commit/8bae913552fa3edae18741871b84b27b88c2c8ad))
* **projects:** add auto-pick issues toggle ([4c954e0](https://github.com/viamin/paid/commit/4c954e09d5b72f835f889fb8cee6eedae0a9b7af))
* **projects:** add auto-pick issues toggle to project page ([80813e0](https://github.com/viamin/paid/commit/80813e04b8e3ab6a212f2beac53bf3423bf04b60)), closes [#323](https://github.com/viamin/paid/issues/323)
* **release:** add release-please workflow and semantic commit enforcement ([92757e1](https://github.com/viamin/paid/commit/92757e1933aeb15c1e705f1ad030fbd1fd4dc3c9))
* **release:** add release-please workflow and semantic commit enforcement ([0b38d7f](https://github.com/viamin/paid/commit/0b38d7f516b2cafef436d68b5c7f24fcb2d1d853))


### Bug Fixes

* add defense-in-depth author_association check to Claude workflow ([27ac27e](https://github.com/viamin/paid/commit/27ac27e6c166860cb0077922e3e02cf819dd6b0b))
* add retry/backoff to re-verify step and document CodeQL accepted risk ([a76b2b0](https://github.com/viamin/paid/commit/a76b2b0963f05ce22f2b2e61b6187a4d6586d8ba))
* add top-level permissions: {} and use ::warning:: for non-error annotations ([98465c9](https://github.com/viamin/paid/commit/98465c97cd3c55c4d8079a85357a0819c7f0a681))
* address remaining security review feedback on Claude workflows ([a281497](https://github.com/viamin/paid/commit/a281497bd2324f4824b371cdb098a8dc40cf062d))
* address remaining security review feedback on Claude workflows ([3e4a56d](https://github.com/viamin/paid/commit/3e4a56d3a30bf2829f1df76a73d4f5eb3d1649e1))
* address review feedback on CI gate and phase labels ([5a27691](https://github.com/viamin/paid/commit/5a276915bf371e075f546df0640eabb5520b6c3a))
* address security and permissions review feedback on Claude workflows ([73020a8](https://github.com/viamin/paid/commit/73020a86e89c383bb49255a5d419833c9c569f71))
* **agent-runs:** add require "set" to ProcessRunQueueJob ([952d144](https://github.com/viamin/paid/commit/952d1440fbbbb24cb7dd279438e4f31909364787))
* **agent-runs:** add safe_github_url? helper and remove build artifacts ([14e800b](https://github.com/viamin/paid/commit/14e800b66276fd8bee57a8e8d9ecd1ef3257b025))
* **agent-runs:** address code review feedback for auto-pick labels, capacity, and tests ([c82e1f2](https://github.com/viamin/paid/commit/c82e1f285efde1512a550e4acfc939ec0bdffb9e))
* **agent-runs:** address code review feedback for auto-pick PR ([0235b88](https://github.com/viamin/paid/commit/0235b88d7f8dfd9123ce41c46e232477b692a313))
* **agent-runs:** address code review feedback for auto-pick PR ([e8bee84](https://github.com/viamin/paid/commit/e8bee84b2cdb85591de40afafe0b8b121eb75022))
* **agent-runs:** address code review feedback for rate limit PR ([8756e3d](https://github.com/viamin/paid/commit/8756e3dfb26ab48c22e86ae52ddd2c6076f6238c))
* **agent-runs:** address code review feedback for rate limit tracking ([f30d82c](https://github.com/viamin/paid/commit/f30d82c984cc12c91bf39b8ff1da2916e34487c1))
* **agent-runs:** address PR review comments for capacity activity and migration ([e777399](https://github.com/viamin/paid/commit/e777399ea4502a803d3b78e54fea313833430225))
* **agent-runs:** address PR review comments for capacity checks ([327a29b](https://github.com/viamin/paid/commit/327a29b7f980eb31e0fb8443ff7f15525ca65150))
* **agent-runs:** address PR review comments for max_concurrent_runs ([5308b66](https://github.com/viamin/paid/commit/5308b6605835afa7de432315287b910ad4cd615b))
* **agent-runs:** address PR review comments for query, queue, and migration ([e5c9ff5](https://github.com/viamin/paid/commit/e5c9ff5935e2ff513aef34bbfe2461239f9a1222))
* **agent-runs:** address PR review comments for UI, migration, and code reuse ([9f3524b](https://github.com/viamin/paid/commit/9f3524bd853839f22ad31ba111a9a7ddae057bae))
* **agent-runs:** address PR review feedback for URL safety and N+1 queries ([3036727](https://github.com/viamin/paid/commit/30367270da739f7524bd1444c359f056f62bd62a))
* **agent-runs:** address review comments for consistency and race handling ([5783b20](https://github.com/viamin/paid/commit/5783b207d672c7e760afe789aa929c3e530b75e0))
* **agent-runs:** address review feedback and remove build artifacts ([f45f333](https://github.com/viamin/paid/commit/f45f333d99ae99c23fee4cb8ca603c27f906c34b))
* **agent-runs:** call search_by_goal unconditionally in controllers ([bf831dd](https://github.com/viamin/paid/commit/bf831ddba51b72a214fcfe531c1aac0786dcbe7a))
* **agent-runs:** filter untrusted issues and fix auto-pick test setup ([dcbfb0e](https://github.com/viamin/paid/commit/dcbfb0ef56a91c0e3037f9d3137885204d5339f9))
* **agent-runs:** handle nil created_by in capacity checks and avoid intermediate status flip ([6b643cc](https://github.com/viamin/paid/commit/6b643cc65b77c3c822fc6ed80348b5f8e36a558b))
* **agent-runs:** initialize user_active_count and user_max before conditional block ([fc4622d](https://github.com/viamin/paid/commit/fc4622d41f17db10b1345a9048b9b929cd59ccab))
* **agent-runs:** mark run as rate_limited when all providers skipped due to cached rate limit ([de818e2](https://github.com/viamin/paid/commit/de818e249903b6ab6d9d07049378a06be6725505))
* **agent-runs:** normalize whitespace-only goal filter param ([5846c56](https://github.com/viamin/paid/commit/5846c56ff36878ddc2ffa2a666e243b2784991c9))
* **agent-runs:** remove .pg-local build artifacts from version control ([81af5e3](https://github.com/viamin/paid/commit/81af5e332dab232ddd8eea83fcdcca2b95556b7e))
* **agent-runs:** remove dead goal text search and update specs for new UI ([c3d5198](https://github.com/viamin/paid/commit/c3d51989ea5617a7e124fd7207bb5de34cc1b9a9))
* **agent-runs:** remove redundant remaining_queued snapshot from ProcessRunQueueJob ([d23a2ae](https://github.com/viamin/paid/commit/d23a2ae983c65dd2e07e510dc6c51081de46eb2b))
* **agent-runs:** return `all` from search_by_goal when query is blank ([9aee0cb](https://github.com/viamin/paid/commit/9aee0cb48ed50e799e2fc36a7943e9a92d040639))
* **agent-runs:** scope per-user capacity checks to user's own projects ([3779438](https://github.com/viamin/paid/commit/3779438763774ce6b7cb09e099ff2fe1e56e7ed5))
* **agent-runs:** search_by_goal also matches goal enum, clarify UI label ([7a542b4](https://github.com/viamin/paid/commit/7a542b462804d37cf814059610adc420f7126257))
* **agent-runs:** split container resource and concurrency default specs ([df00636](https://github.com/viamin/paid/commit/df00636ef0ab6c20abd2b50da5a750b2305ee1c3))
* **agent-runs:** update schema version and remove build artifact ([60e8e15](https://github.com/viamin/paid/commit/60e8e1521634a4e4c4fa0e3c5375708b8a340021))
* **agent-runs:** update STATUSES constant test to include rate_limited ([49c7f6d](https://github.com/viamin/paid/commit/49c7f6d00e9d4a37314b73887e54b8ae5b573967))
* **agent-runs:** use @&gt; operator instead of ?| for JSONB label exclusion ([e89aaf5](https://github.com/viamin/paid/commit/e89aaf56533180f6e948039575bc1ae7e6743275))
* **agent-runs:** use attribute matching instead of object identity in auto-pick specs ([650df62](https://github.com/viamin/paid/commit/650df621aaf7964ef4eafa7c51a99dc9bba410b3))
* **agent-runs:** use ILIKE for goal column in search_by_goal scope ([57e7820](https://github.com/viamin/paid/commit/57e7820a78c82a0dd74d348364786a36ecf104a6))
* checkout base SHA in Claude code review workflow to prevent untrusted code execution ([2b7d5ef](https://github.com/viamin/paid/commit/2b7d5ef1b1959591045e16c615e5ded96ec9dd6b))
* clarify OAuth token requirement in Claude workflow comments ([483d85b](https://github.com/viamin/paid/commit/483d85beb6cd89995b65893e97a78a4513b272d8))
* **db:** sync schema.rb with actual database state ([edee11a](https://github.com/viamin/paid/commit/edee11a6670a0be31d8e3cc65b29e9e3d172c31f))
* **db:** sync schema.rb with actual database state ([2ca2b29](https://github.com/viamin/paid/commit/2ca2b2980e230a6762f02ae404a1eb3336e2cf6f))
* make [@claude](https://github.com/claude) mention matching case-insensitive ([428ce25](https://github.com/viamin/paid/commit/428ce25999b13da04cadde68a3a4f22571a1c471))
* mitigate TOCTOU and untrusted checkout CodeQL alerts in Claude workflow ([626c0f8](https://github.com/viamin/paid/commit/626c0f8bc2031f033401791c70d47664f6e29225))
* **projects:** add error handling and tests for auto-pick toggle ([9fc46cc](https://github.com/viamin/paid/commit/9fc46cc4805684563e787a7aebbbd87fb19b27e5))
* **providers:** address code review feedback on PR [#321](https://github.com/viamin/paid/issues/321) ([66c6666](https://github.com/viamin/paid/commit/66c66661425b216ad3bacf87cc662f7f4beb2f24))
* **providers:** remove env-gated fallback provider availability ([854a840](https://github.com/viamin/paid/commit/854a840687a1b1a0c74c622ffa66da28e54ea913))
* **providers:** remove env-gated fallback provider availability ([dced27c](https://github.com/viamin/paid/commit/dced27ced3c14443e7cfe1b41fd11a0a64018ecd))
* **release:** address PR review feedback ([1b3c19b](https://github.com/viamin/paid/commit/1b3c19b0e78c6132432f5b235b8f3a30bd96c239))
* **release:** allow amend! commits in commit-msg hook ([74e8b5d](https://github.com/viamin/paid/commit/74e8b5d6e0dbe86796844911584433bf9268179c))
* remove explicit checkout from Claude workflow to resolve CodeQL alerts ([3451153](https://github.com/viamin/paid/commit/34511535b88c68292a35c0f501b119961a91ec8f))
* remove unintended schema.rb changes ([58a1b90](https://github.com/viamin/paid/commit/58a1b90c7ab42356c1d4cb27f72699e081d2d9bc))
* resolve PR base SHA via API for issue_comment events and fix plugin_marketplaces ref ([934c162](https://github.com/viamin/paid/commit/934c162e031d678e2bfe3ba5d7ec56801d337bac))
* **settings:** make reconciliation migration irreversible ([f84f7e6](https://github.com/viamin/paid/commit/f84f7e6504c91082795ccad6fb99ad4387a12ee8))
* **settings:** reconcile missing container_cpu_quota column ([9089016](https://github.com/viamin/paid/commit/9089016839f10b77f4e9892a4a48c46fb384b43e))
* **settings:** reconcile missing container_cpu_quota column ([c3fd091](https://github.com/viamin/paid/commit/c3fd091df784480432b3be6eccf7b1cf7e9dc75d))
* split Claude workflow into verify + claude jobs for security ([7ce7e76](https://github.com/viamin/paid/commit/7ce7e761d0139750779fe0829c5863b561f6d467))
* **temporal:** add ProviderTimeoutError to YARD doc for run_agent_with_provider ([f633175](https://github.com/viamin/paid/commit/f6331758cc34c97e10cb34050c1b250f235d5129))
* **temporal:** address PR [#316](https://github.com/viamin/paid/issues/316) review feedback ([33ba9dd](https://github.com/viamin/paid/commit/33ba9ddc68019b009fa8883672c5a556f85cbd87))
* **temporal:** keep agent child workflows alive across poll rollover ([7113aa6](https://github.com/viamin/paid/commit/7113aa66c17aabba476860ff7b7d622d0178e917))
* use env vars instead of direct interpolation for github context in Claude workflow ([2694d70](https://github.com/viamin/paid/commit/2694d70359f4de4bdd675882547e77ac7e5941fd))
* use immutable SHA fallback in Claude workflow checkout to address CodeQL TOCTOU alert ([f06fee5](https://github.com/viamin/paid/commit/f06fee508511640a71bf70f5132bfdacc0f4c6b9))
* use immutable SHA ref in Claude workflow checkout to mitigate TOCTOU ([4cbbaa5](https://github.com/viamin/paid/commit/4cbbaa5777ed3b4c2c6f1aea8f889eb6e011b702))

## Changelog

All notable changes to this project are documented in this file.
