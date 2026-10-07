# frozen_string_literal: true

module Automation
  module Strategies
    class AutoPick
      # Default (GitHub-backed) implementation of {CandidateSource}.
      #
      # Reads Paid's local work-item store — the {::Issue} table seeded by
      # the GitHub sync — and applies the shared per-issue eligibility and
      # ordering rules that historically lived inside {Issues::AutoPick}.
      #
      # Eligibility rules:
      # - Open, non-PR issues with all structured dependencies satisfied
      # - No unfinished agent run already attached to the issue
      # - No open PR linked back to the issue via +parent_issue_id+
      # - Not labeled with any configured auto-pick skip labels
      # - Not a parent issue with still-open sub-issues, and not a tracker /
      #   meta issue whose body still references open work items
      # - Issue creator is in the project's trusted allowlist when one is
      #   configured
      #
      # Ordering rules (applied together inside one SQL query so Postgres
      # can plan efficiently):
      # - Priority label tier first (P1 > P2 > P3 > unlabeled), using each
      #   project's configured priority label names
      # - Then prefer runnable dependency-tree roots that already unblock
      #   other open work over standalone terminal issues
      # - Then by +github_number+ ascending (FIFO — older issues within
      #   the same priority tier are always picked first so they don't
      #   get starved by newer issues)
      module DefaultCandidateSource
        extend CandidateSource

        # SQL ILIKE patterns used to pre-filter potential tracker issues
        # before applying the full Ruby-level +Issue#tracker_issue?+
        # check. The Ruby check matches tracker vocabulary in the title
        # OR inside a markdown heading in the body; each SQL pattern here
        # must be a *superset* of both branches so that no tracker
        # escapes the prefilter (e.g. +%remaining%work%+ covers any
        # whitespace variant that +remaining\s+work+ would match, and
        # +%tracker%+ covers both "## Tracker" headings and bare-word
        # title matches).
        TRACKER_SQL_PATTERNS = [
          "%tracker%",
          "%remaining%work%",
          "%completion%criteria%",
          "%phase%tracker%",
          "%meta%issue%"
        ].freeze

        # Bounds how long a +create_pr+ run without a locally synced
        # resolution keeps its source issue out of auto-pick.
        # +agent_runs.pull_request_number+ is persisted the moment the run
        # publishes its PR — before terminal status (see
        # CreatePullRequestActivity#reserve_pull_request!) — and every
        # terminal transition stamps +completed_at+, so the window below
        # covers completed, failed, and cancelled runs alike. The local PR
        # +Issue+ row (and its +parent_issue_id+ linkage) is written later
        # by GitHub sync. Without a bounded check on that gap, auto-pick
        # can re-pick the source issue and open a second PR before sync
        # catches up (#3432). The window is bounded, not permanent, so a
        # PR row that never syncs (deleted branch, stale/wrong recorded PR
        # number, sync backlog) does not strand the issue forever.
        PR_SYNC_GRACE_PERIOD = 1.hour
        EPIC_LABEL = "epic"
        # A reconciliation that persisted assessment gaps, or exhausted its
        # retries after publishing a PR, is the durable partial-closeout
        # signal (NO-OUTPUT-ISSUE-007): the run's PR is progress evidence,
        # not a terminal outcome for the parent. The jsonb_typeof guard keeps
        # a corrupted non-array gaps value from failing the whole
        # eligible-scope query.
        PARTIAL_CLOSEOUT_GAPS_CONDITION =
          "((jsonb_typeof(reconciliation->'assessment'->'gaps') = 'array' " \
          "AND jsonb_array_length(reconciliation->'assessment'->'gaps') > 0) " \
          "OR reconciliation->>'status' = 'retryable_failure')"

        class << self
          def eligible_issue_ids(displayed_issues)
            return Set.new if displayed_issues.empty?

            displayed_ids = displayed_issues.map(&:id)
            project = displayed_issues.first.project
            eligible_scope(project)
              .where(id: displayed_ids)
              .pluck(:id)
              .to_set
          end

          # Rechecks a single issue's eligibility at dequeue time. The
          # queued run being considered is itself a blocking run, so it
          # must be excluded from the "issue already has work in flight"
          # filter (otherwise every queued run would self-exclude its own
          # issue and be wrongly cancelled). Pass +excluding_run_id: <the
          # candidate run's id>+. Returns true when the issue is still
          # auto-pick eligible ignoring that one run.
          #
          # +continuation_authorized_issue_ids+ lifts only the merged-PR and
          # no-code guards for exactly those issues (a scoped continuation
          # authorization, @spec PARTIAL-CLOSEOUT-004); every other guard
          # still applies. It defaults to none so plain auto-pick semantics
          # are unchanged.
          def eligible_for_dequeue?(project, issue_id, excluding_run_id:, continuation_authorized_issue_ids: [])
            eligible_scope(
              project,
              excluding_run_id: excluding_run_id,
              continuation_authorized_issue_ids: continuation_authorized_issue_ids
            )
              .where(id: issue_id)
              .exists?
          end

          def eligible_scope(project, excluding_run_id: nil, continuation_authorized_issue_ids: []) # @spec AUTO-PICK-QUEUE-004 AUTO-PICK-QUEUE-005 AUTO-PICK-QUEUE-007 @spec PARTIAL-CLOSEOUT-004
            epic_ids = epic_issue_ids(project)
            base = without_open_non_pr_subissues(
              base_scope(
                project,
                epic_ids: epic_ids,
                excluding_run_id: excluding_run_id,
                continuation_authorized_issue_ids: continuation_authorized_issue_ids
              )
            )
            scope = Issue.auto_pick_eligible_paid_state_scope(base)

            blocked_ids = tracker_ids_blocked_by_open_references(scope, project)
            unless blocked_ids.empty?
              # An epic umbrella's readiness is governed by its authoritative
              # child/dependency relationships, so incidental open body
              # references must not strand it behind tracker heuristics.
              blocked_ids -= epic_ids
              scope = scope.where.not(id: blocked_ids) unless blocked_ids.empty?
            end

            scope = apply_issue_analysis_backoff(scope, project)

            # @spec INTENT-AMENDMENT-009 — branches held by a design
            # amendment stay out of selection while the hold is active.
            held_ids = DesignAmendmentPause.held_issue_ids(project)
            scope = scope.where.not(id: held_ids) if held_ids.present?

            # @spec FEATURE-APPROVAL-023 — a linked feature tree stays out
            # of every automatic selection path until its release transaction
            # has recorded a repository revision.
            held_feature_issue_ids = FeatureIntentIssue.joins(:feature_intent)
              .where(feature_intents: { project_id: project.id })
              .where.not(feature_intents: { status: "released" })
              .select(:issue_id)
            scope = scope.where.not(id: held_feature_issue_ids)

            missing_revision_issue_ids = FeatureIntentIssue.joins(:feature_intent)
              .where(feature_intents: { project_id: project.id, status: "released", approved_design_revision: nil })
              .select(:issue_id)
            scope = scope.where.not(id: missing_revision_issue_ids)

            # @spec AUTO-PICK-QUEUE-011 — issues whose latest model
            # selection pins a tier no configured runner can satisfy stay
            # out of selection so auto-pick stops creating doomed runs
            # (#4093).
            tier_blocked_ids = tier_infeasible_issue_ids(scope, project)
            scope = scope.where.not(id: tier_blocked_ids) if tier_blocked_ids.present?

            scope
          end

          def ordered_scope(project, excluding_run_id: nil)
            eligible_scope(project, excluding_run_id: excluding_run_id)
              .order(
                Arel::Nodes::Ascending.new(priority_label_order_node(project)),
                Arel::Nodes::Ascending.new(dependency_tree_order_node),
                Issue.arel_table[:github_number].asc
              )
          end

          def next_candidate(project)
            ordered_scope(project).first
          end

          # Identifies tracker issues whose body references other issues
          # that are still open. Uses a SQL pre-filter (ILIKE) to narrow
          # candidates, then applies the full Ruby-side
          # +Issue#tracker_issue?+ check and reference parsing. Only
          # queries open/closed state for issue numbers actually
          # referenced by tracker candidates (not all project issues).
          #
          # +candidate_scope+ is the already-filtered eligible-issue scope
          # so the ILIKE scan runs only against issues that passed earlier
          # filters (labels, dependencies, active runs, etc.) rather than
          # all open project issues. If this still becomes expensive on
          # repos with thousands of eligible issues, consider a trigram
          # GIN index on (title, body) or a persisted +tracker_issue+
          # boolean column.
          #
          # Blocking policy:
          # - Trackers with body references are blocked when ANY reference
          #   is open or unknown (not yet synced). Only direct references
          #   are checked — not transitive dependencies of those
          #   references. Transitive checking is deferred because the
          #   IssueDependency graph may be incomplete for body-referenced
          #   issues, and the direct-reference check already catches the
          #   motivating scenario (#615).
          # - Trackers with NO body references are conservatively blocked
          #   ONLY when the title itself matches tracker vocabulary. A
          #   body-heading match alone (e.g. "## Completion criteria") is
          #   a weaker signal — common in regular implementation issues —
          #   so those are allowed through unless they have open refs.
          def tracker_ids_blocked_by_open_references(candidate_scope, project)
            ilike_conditions = TRACKER_SQL_PATTERNS.each_with_index.flat_map do |_, i|
              [ "title ILIKE :t#{i}", "body ILIKE :t#{i}" ]
            end
            params = TRACKER_SQL_PATTERNS.each_with_index.to_h do |pattern, i|
              [ :"t#{i}", pattern ]
            end

            candidates = candidate_scope.where(ilike_conditions.join(" OR "), **params)
              .select(:id, :github_number, :title, :body)
            return [] if candidates.empty?

            refs_by_issue = candidates.filter_map do |issue|
              next unless issue.tracker_issue?

              refs = issue.body_referenced_issue_numbers - [ issue.github_number ]
              [ issue.id, refs, Issue::TRACKER_PATTERN.match?(issue.title.to_s), issue.strong_tracker_body_heading? ]
            end
            return [] if refs_by_issue.empty?

            no_ref_ids = refs_by_issue.filter_map do |id, refs, title_match, strong_body_match|
              id if refs.empty? && (title_match || strong_body_match)
            end
            with_refs = refs_by_issue.filter_map { |id, refs, _, _| [ id, refs ] if refs.present? }
            return no_ref_ids if with_refs.empty?

            all_referenced_numbers = with_refs.flat_map(&:last).uniq

            # Fetch referenced issues (any state) to distinguish open,
            # closed, and unknown. Unknown (missing) references are
            # treated as blocking to avoid auto-picking trackers when
            # sync is incomplete.
            referenced_states = Issue.where(
              project: project,
              is_pull_request: false,
              github_number: all_referenced_numbers
            ).pluck(:github_number, :github_state).to_h

            unknown_numbers = all_referenced_numbers.reject { |num| referenced_states.key?(num) }
            DependencyBackfillJob.perform_later(project.id, unknown_numbers) if unknown_numbers.any?

            blocked_with_refs = with_refs.filter_map do |issue_id, refs|
              issue_id if refs.any? do |num|
                state = referenced_states[num]
                state.nil? || state == "open"
              end
            end

            no_ref_ids + blocked_with_refs
          end

          private

          # @spec AUTO-PICK-QUEUE-011
          # Issues whose most recent model selection pins a tier that no
          # runner the project's owner has enabled for agent runs can
          # satisfy stay out of selection. The latest selection is the
          # predictor for what the next run would pin — selection inputs
          # (project model preferences, quality-escalation config, issue
          # complexity) are deterministic per issue, so a run that failed
          # for tier infeasibility would be re-selected with the same tier.
          # Feasibility is re-derived from live runner configuration on
          # every pass, so the exclusion clears itself as soon as a capable
          # runner is configured — no persisted flag to reset. The
          # dispatch-time filter in RunAgentActivity remains the final gate.
          def tier_infeasible_issue_ids(candidate_scope, project)
            tiers_by_issue = latest_requested_tier_by_issue_id(candidate_scope)
            return [] if tiers_by_issue.empty?

            infeasible_tiers = infeasible_tiers(project, tiers_by_issue.values.uniq)
            return [] if infeasible_tiers.empty?

            tiers_by_issue.select { |_issue_id, tier| infeasible_tiers.include?(tier) }.keys
          end

          # Latest non-blank model-selection tier per issue id, restricted to
          # the issues already present in +candidate_scope+ so the join only
          # touches eligible issues.
          def latest_requested_tier_by_issue_id(candidate_scope)
            ModelSelection.joins(:agent_run)
              .where(agent_runs: { issue_id: candidate_scope.select(:id) })
              .where.not(tier: [ nil, "" ])
              .order(model_selections: { created_at: :desc })
              .pluck("agent_runs.issue_id", "model_selections.tier")
              .each_with_object({}) do |(issue_id, tier), map|
                map[issue_id] ||= tier
              end
          end

          def infeasible_tiers(project, tiers)
            user = project.effective_owner
            return [] if user.nil?

            runners = user.runners.kept_only.for_agent_runs
              .where(runner_key: RunnerSupport.container_executable_runner_keys)
              .ordered

            tiers.select { |tier| !Runners::TierCapability.any_supports_tier?(runners, tier, user: user) }
          end

          def apply_issue_analysis_backoff(scope, project) # @spec ISSUE-ANALYSIS-010 AUTO-PICK-QUEUE-002
            # The reset timestamp only matters for rows with a non-null
            # `issue_analysis_next_attempt_at`. Skip the (expensive) reset
            # context query when no issue is in active backoff — the
            # overwhelmingly common case across dequeue-time rechecks,
            # sweep jobs, and dashboard eligibility breakdowns.
            return scope unless project.issues.where.not(issue_analysis_next_attempt_at: nil).exists?

            now = Time.current
            reset_at = Issues::IssueAnalysisBackoffResetContext.call(project: project)

            if reset_at
              scope.where(
                "issues.issue_analysis_next_attempt_at IS NULL OR " \
                "issues.issue_analysis_next_attempt_at <= ? OR " \
                "issues.issue_analysis_backoff_set_at < ?",
                now,
                reset_at
              )
            else
              scope.where("issues.issue_analysis_next_attempt_at IS NULL OR issues.issue_analysis_next_attempt_at <= ?", now)
            end
          end

          def base_scope(project, epic_ids:, excluding_run_id: nil, continuation_authorized_issue_ids: []) # @spec EAGER-QUEUE-009
            blocking_runs = AgentRun.where(
              project: project, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
            ).where.not(issue_id: nil)
            # At dequeue time the candidate run itself is a blocking run; ignore
            # it so the issue is not self-excluded by the "work already in
            # flight" filter (RDR-032 dequeue-time eligibility recheck).
            blocking_runs = blocking_runs.where.not(id: excluding_run_id) if excluding_run_id
            blocking_issue_ids = blocking_runs.select(:issue_id)

            reauditable_issue_ids = reauditable_issue_ids(project, epic_ids)
            reauditable_closeout_ids = partial_closeout_reaudit_issue_ids(project)
            prerequisite_block_ids = partial_closeout_prerequisite_block_issue_ids(project)
            # @spec PARTIAL-CLOSEOUT-004 — a scoped continuation authorization
            # lifts ONLY the merged-PR and no-code guards below, and only for
            # the explicitly authorized issues. Every other guard applies
            # unchanged, and plain auto-pick (no authorized ids) behaves
            # exactly as before.
            authorized_ids = Array(continuation_authorized_issue_ids)

            base = Issue.ready_for_work(project)
              .where.not(id: blocking_issue_ids)
              .where(source: [ Issue::GITHUB_SOURCE, Issue::SYNTHETIC_CODE_SCANNING_SOURCE ])
              .where.not(id: Issue.open_pull_request_parent_issue_ids(project: project).distinct)
              .where.not(id: Issue.open_paid_generated_pull_request_source_issue_ids(project: project).distinct)
              # Applies regardless of paid_state so a create_pr run that
              # already recorded a PR number cannot be immediately re-picked
              # while local PR sync is still catching up (#3432).
              .where.not(id: unsynced_pr_produced_issue_ids(project))
              # Once a merged PR row is authoritatively linked back to its
              # source issue (via +parent_issue_id+ or the originating run's
              # recorded +pull_request_number+), the issue stays ineligible
              # regardless of paid_state. This permanent guard intentionally
              # does NOT trust bare +pull_request_number+ alone past
              # PR_SYNC_GRACE_PERIOD, so a stale or wrong recorded PR number
              # cannot strand the issue forever (#3432/#3588 review follow-up).
              # For a synthetic code-scanning issue the guard is provisional,
              # not permanent — see +merged_block_issue_ids+ (#4052). A
              # recorded partial closeout is the other exception: its merged
              # PR is partial progress, and the parent must re-enter
              # selection once the gap owners resolve (#4119).
              .where.not(id: merged_block_issue_ids(project) - reauditable_issue_ids - reauditable_closeout_ids - authorized_ids)
              # A code-scanning remediation remains blocked until a matching
              # post-merge analysis records a terminal verification result.
              # In particular, a still-open finding moves to manual review,
              # rather than being silently re-enqueued into another fix loop.
              .where.not(id: code_scanning_verification_block_issue_ids(project))
              # Issues abandoned because every available provider hit the per-issue
              # retry cap (#2513) are not auto-pickable until the abandonment is
              # cleared (e.g. by a successful run).
              .where(runner_retry_abandoned_at: nil)
              # An agent-declared no-code-required completion is terminal: unlike
              # the generic completed-issue recovery below, re-picking it would
              # just loop (the agent will likely declare no-code-required again).
              # Applies regardless of paid_state so this guard survives a later
              # paid_state reset the same way the merged-PR guard above does.
              .where("issues.no_code_required_at IS NULL OR issues.id IN (?)", reauditable_issue_ids + authorized_ids)
              # Partial-closeout human prerequisites surface as blocking Inbox
              # notifications rather than durable IssueDependency edges
              # (NO-OUTPUT-ISSUE-007). Without this exclusion the partial-closeout
              # re-audit exception above would re-pick the parent once the partial
              # PR merges, even though the operator has not yet completed the
              # prerequisite the notification states. The notification dismissal
              # or system resolve clears the block (see Notification's callback),
              # so the parent re-enters selection through the same eager-enqueue
              # path that dependency resolution uses.
              .where.not(id: prerequisite_block_ids)

            trusted_usernames = project.trusted_github_author_logins.presence
            if trusted_usernames
              base = base.where("LOWER(issues.github_creator_login) IN (?)", trusted_usernames)
            end

            needs_input_excluded = project.needs_input_labels.reduce(base) do |scope, label|
              scope.where.not("labels @> ?::jsonb", [ label ].to_json)
            end

            project.effective_auto_pick_skip_labels.reduce(needs_input_excluded) do |scope, label|
              scope.where.not("labels @> ?::jsonb", [ label ].to_json)
            end
          end

          # Issue ids with a +create_pr+ run that recorded a PR number
          # within the last {PR_SYNC_GRACE_PERIOD} but has no local, synced
          # PR +Issue+ row proving that PR is closed without merging. The
          # run's recorded number — not its terminal status — is the
          # evidence: a run can fail or be cancelled after the PR was
          # already published, and every terminal transition stamps
          # +completed_at+ to arm this window (an unfinished run is blocked
          # by AUTO_PICK_BLOCKING_STATUSES instead). An open synced PR is
          # already excluded by +Issue.open_pull_request_parent_issue_ids+;
          # this covers the window where the PR row hasn't synced at all
          # yet, or sync hasn't caught up with a just-closed-unmerged PR
          # (#3432).
          def unsynced_pr_produced_issue_ids(project) # @spec EAGER-QUEUE-009
            AgentRun.where(project: project, goal: "create_pr")
              .where.not(pull_request_number: nil).where.not(issue_id: nil)
              .where("agent_runs.completed_at > ?", PR_SYNC_GRACE_PERIOD.ago)
              .where("NOT EXISTS (#{Issue::AUTO_PICK_CLOSED_PR_CORRELATED_SUBQUERY})")
              .select(:issue_id)
          end

          # Issue ids with a merged PR row authoritatively linked back to the
          # source issue via +parent_issue_id+. Unlike the grace-window check
          # above, this does not depend on bare +pull_request_number+, so a
          # stale/wrong recorded PR number cannot permanently block the issue.
          def merged_linked_pr_parent_issue_ids(project)
            Issue.where(project: project, is_pull_request: true, pr_review_phase: "merged")
              .where.not(parent_issue_id: nil)
              .select(:parent_issue_id)
          end

          # Union of both merged-PR evidence sources, with the permanent
          # exclusion relaxed for synthetic code-scanning issues: a merge is
          # not proof a scanner-reported alert is fixed, only the next
          # SecurityAlerts::ProcessCodeScanningAlerts pass is (#4052). An
          # ordinary GitHub issue's merged PR keeps blocking it forever, same
          # as before.
          def merged_block_issue_ids(project) # @spec EAGER-QUEUE-011
            merged_ids = (
              merged_linked_pr_parent_issue_ids(project).pluck(:parent_issue_id) +
              Issue.merged_paid_generated_pull_request_source_issue_ids(project: project).pluck(:issue_id)
            ).uniq
            return [] if merged_ids.empty?

            code_scanning_ids = Issue.where(id: merged_ids, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE).pluck(:id)
            return merged_ids if code_scanning_ids.empty?

            merged_ids - verified_recurrent_code_scanning_issue_ids(project, code_scanning_ids)
          end

          # An epic is a final acceptance audit, not ordinary implementation
          # work. A prior no-code outcome or merged audit PR remains terminal
          # until child/dependency work linked after that audit resolves.
          # That lets a newly discovered gap complete before one further audit
          # without weakening the terminal guards for ordinary issues.
          def reauditable_epic_ids(project, epic_ids) # @spec AUTO-PICK-QUEUE-010
            return [] if epic_ids.empty?

            terminal_at = terminal_audit_times(project, epic_ids)
            return [] if terminal_at.empty?

            resolved_prerequisite_linked_at(project, epic_ids).filter_map do |issue_id, linked_at|
              issue_id if linked_at > terminal_at.fetch(issue_id, Time.at(0))
            end
          end

          # A partial closeout's merged PR is progress evidence, not a
          # terminal outcome for the parent (#4119): the parent re-enters
          # selection for a continuation run once the shared gates that
          # govern every other issue clear — the gap-owner dependencies
          # (+ready_for_work+) and the open paid-generated PR guards (the
          # partial PR must merge or close first). Keyed on the issue's
          # latest PR-producing run so a later gap-free closeout, which
          # completes the parent, restores the permanent merged-PR guard —
          # while a re-audit attempt that fails before publishing another PR
          # supersedes nothing and keeps the exception armed.
          def partial_closeout_reaudit_issue_ids(project) # @spec NO-OUTPUT-ISSUE-007
            latest_run_ids = AgentRun.where(project: project, goal: "create_pr")
              .where.not(issue_id: nil).where.not(pull_request_number: nil)
              .group(:issue_id)
              .pluck(:issue_id, Arel.sql("MAX(id)"))
              .to_h
            return [] if latest_run_ids.empty?

            AgentRun.where(id: latest_run_ids.values)
              .where(PARTIAL_CLOSEOUT_GAPS_CONDITION)
              .pluck(:issue_id)
          end

          # Issue ids whose partial closeout surfaced one or more human
          # prerequisites (NO-OUTPUT-ISSUE-007). Unlike agent gaps, which
          # produce durable IssueDependency edges that the shared
          # +ready_for_work+ gate filters, human prerequisites publish a
          # blocking Inbox notification whose subject is the parent issue.
          # The notification is the durable scheduling block until the
          # operator dismisses it (Inbox dismiss action) or the system
          # resolves it (Notifications::Resolve), so the partial-closeout
          # re-audit exception does not re-pick the parent ahead of the
          # prerequisite the notification names.
          def partial_closeout_prerequisite_block_issue_ids(project) # @spec NO-OUTPUT-ISSUE-007
            Notification.where(
              account_id: project.account_id,
              source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
              subject_type: "Issue"
            ).where(resolved_at: nil, dismissed_at: nil)
              .where("subject_id IN (?)", project.issues.select(:id))
              .pluck(:subject_id)
          end

          # A merged PR remains terminal for ordinary implementation work unless
          # Paid has durably assessed that it was partial. That assessment carries
          # the same authoritative child/dependency graph used for epic audits;
          # a prerequisite resolving after the assessment permits one fresh run.
          # The strict resolution-time comparison makes polling and metadata sync
          # idempotent, rather than treating a merge or an incidental update as a
          # reason to run again. @spec AUTO-PICK-QUEUE-012 EAGER-QUEUE-009
          def reauditable_issue_ids(project, epic_ids)
            reauditable_epic_ids(project, epic_ids) + continuable_partial_issue_ids(project)
          end

          def continuable_partial_issue_ids(project)
            partial_times = Issue.where(project: project, is_pull_request: false, github_state: "open")
              .where.not(partial_completion_at: nil)
              .pluck(:id, :partial_completion_at).to_h
            return [] if partial_times.empty?

            resolved_prerequisite_linked_at(project, partial_times.keys).filter_map do |issue_id, resolved_at|
              issue_id if resolved_at > partial_times.fetch(issue_id)
            end
          end

          def epic_issue_ids(project)
            Issue.where(project: project, is_pull_request: false, github_state: "open")
              .where("labels @> ?::jsonb", [ EPIC_LABEL ].to_json)
              .pluck(:id)
          end

          def terminal_audit_times(project, issue_ids)
            no_code_times = Issue.where(id: issue_ids).where.not(no_code_required_at: nil)
              .pluck(:id, :no_code_required_at).to_h
            merged_pr_terminal_audit_at_by_issue_id(project, issue_ids).each do |issue_id, terminal_at|
              no_code_times[issue_id] = [ no_code_times[issue_id], terminal_at ].compact.max
            end
            no_code_times
          end

          # Latest terminal time at which a create_pr audit concluded for each
          # issue id, combining both evidence sources (authoritative
          # +parent_issue_id+ link and the originating run's recorded
          # +pull_request_number+) the same way +merged_block_issue_ids+ does.
          # Reads +agent_runs.completed_at+ (set once on terminal transition)
          # when an originating run exists for the merged PR; otherwise falls
          # back to the PR row's +created_at+ (when Paid first observed the
          # row). Deliberately avoids the merged PR row's +updated_at+ — the
          # latter is bumped on every Issue#save (label sync, comment fetch,
          # and Issues::UpsertFromGithub.call re-saving the merged PR row all
          # do). With +reauditable_epic_ids+ enforcing a strict +linked_at >
          # terminal_at+ comparison, a later sync bumping the PR's
          # +updated_at+ would otherwise move +terminal_at+ forward and wrongly
          # block a re-audit even after the newly linked work resolves — the
          # same immutability rationale +resolved_prerequisite_linked_at+
          # applies to its own +updated_at+ sources.
          def merged_pr_terminal_audit_at_by_issue_id(project, issue_ids)
            linked = Issue.where(project: project, is_pull_request: true, pr_review_phase: "merged", parent_issue_id: issue_ids)
              .pluck(:parent_issue_id, :github_number, :created_at)

            run_linked = AgentRun.where(project: project, goal: "create_pr", issue_id: issue_ids)
              .where.not(pull_request_number: nil).where.not(completed_at: nil)
              .joins(<<~SQL.squish)
                INNER JOIN issues merged_prs
                  ON merged_prs.project_id = agent_runs.project_id
                 AND merged_prs.github_number = agent_runs.pull_request_number
                 AND merged_prs.is_pull_request = TRUE
                 AND merged_prs.pr_review_phase = 'merged'
              SQL
              .pluck("agent_runs.issue_id", "agent_runs.pull_request_number", "agent_runs.completed_at")

            run_completed_at_by_pr = run_linked.each_with_object({}) do |(run_issue_id, pr_number, completed_at), result|
              next unless pr_number

              existing = result[pr_number]
              result[pr_number] = completed_at if existing.nil? || completed_at > existing
            end

            result = {}
            linked.each do |epic_id, pr_number, pr_created_at|
              terminal_at = run_completed_at_by_pr[pr_number] || pr_created_at
              next if terminal_at.nil?

              existing = result[epic_id]
              result[epic_id] = terminal_at if existing.nil? || terminal_at > existing
            end
            run_linked.each do |run_issue_id, _pr_number, completed_at|
              next if completed_at.nil?

              existing = result[run_issue_id]
              result[run_issue_id] = completed_at if existing.nil? || completed_at > existing
            end
            result
          end

          # A terminal audit may re-arm once for work that resolves *after*
          # the audit terminates. Compare the *resolution* timestamp — not
          # the link timestamp — against the audit's terminal time:
          #
          # - +closed_at+ is stamped on the open -> closed transition and is
          #   untouched by later label/comment syncs (unlike +updated_at+ and
          #   +github_updated_at+), so it stays stable for already-resolved
          #   prerequisites.
          # - For children linked via +parent_issue_id+, fall back to
          #   +parent_issue_linked_at+ (which can fall mid-run when the audit
          #   filed the work itself) and finally to +created_at+ for legacy
          #   rows that predate +parent_issue_linked_at+.
          # - For dependencies, fall back to +issue_dependencies.created_at+
          #   (the edge creation time) when +closed_at+ isn't stamped.
          # - For external owner/repo#N dependencies, mirror
          #   {Issue.ready_for_work}'s `blocked_by_external` rule via
          #   {IssueDependency.external_resolved_for_account} and use the
          #   matching target issue's +closed_at+ as the stable
          #   resolution timestamp (AUTO-PICK-QUEUE-012). External deps
          #   whose target project is not in the same account or whose
          #   target issue is not synced contribute NULL rows that the
          #   strict comparison drops, mirroring the conservative local
          #   fallback.
          def resolved_prerequisite_linked_at(project, issue_ids)
            child_times = Issue.where(parent_issue_id: issue_ids, is_pull_request: false)
              .where("github_state = 'closed' OR paid_state IN (?)", Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
              .group(:parent_issue_id)
              .maximum(Arel.sql("COALESCE(closed_at, parent_issue_linked_at, created_at)"))
            dependency_times = IssueDependency.joins(:depends_on_issue)
              .where(issue_id: issue_ids)
              .where("issues.github_state = 'closed' OR issues.paid_state IN (?)", Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
              .group(:issue_id)
              .maximum(Arel.sql("COALESCE(issues.closed_at, issue_dependencies.created_at)"))
            external_dependency_times = IssueDependency
              .external_resolved_for_account(project.account_id)
              .where(issue_id: issue_ids)
              .where("ext_issue.github_state = 'closed' OR ext_issue.paid_state IN (?)",
                Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
              .group(:issue_id)
              .maximum(Arel.sql("COALESCE(ext_issue.closed_at, issue_dependencies.created_at)"))

            (child_times.keys | dependency_times.keys | external_dependency_times.keys).to_h do |issue_id|
              [ issue_id, [ child_times[issue_id], dependency_times[issue_id], external_dependency_times[issue_id] ].compact.max ]
            end
          end

          def code_scanning_verification_block_issue_ids(project) # @spec EAGER-QUEUE-013 @spec EAGER-QUEUE-015
            # Only the latest attempt per issue governs eligibility (EAGER-QUEUE-015):
            # a prior `verification_failed` row whose PR was superseded by a fresh
            # merged attempt SHALL NOT keep the issue out of auto-pick. The
            # duplicate-PR prevention guards above remain the durable stop against
            # a second concurrent fix PR (EAGER-QUEUE-009); `retryable_block`
            # attempts are revisited by the verifier on the next scan rather than
            # producing a second fix run.
            CodeScanningRemediationAttempt.blocking_automation
              .latest_per_issue
              .joins(:issue)
              .where(issues: { project_id: project.id, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE })
              .select(:issue_id)
          end

          # Code-scanning issue ids where a later scanner pass has already
          # reconciled the alert since the most recent merged remediation PR
          # was observed — i.e. the scanner confirmed the alert is still open
          # (recurrent) rather than the merge simply not having been rescanned
          # yet. These lift out of the merged-PR block; everything else stays
          # blocked until the next scan runs.
          def verified_recurrent_code_scanning_issue_ids(project, issue_ids)
            last_merge_observed_at = merged_pr_last_observed_at_by_issue_id(project, issue_ids)
            return [] if last_merge_observed_at.empty?

            last_reconciled_at = Issue.where(id: last_merge_observed_at.keys).pluck(:id, :last_scanner_reconciled_at).to_h

            last_merge_observed_at.filter_map do |issue_id, merged_at|
              reconciled_at = last_reconciled_at[issue_id]
              issue_id if reconciled_at && reconciled_at >= merged_at
            end
          end

          # Latest +updated_at+ among the merged PR rows recorded as evidence
          # for each issue id, combining both evidence sources (authoritative
          # +parent_issue_id+ link and the originating run's recorded
          # +pull_request_number+) the same way +merged_block_issue_ids+ does.
          def merged_pr_last_observed_at_by_issue_id(project, issue_ids)
            linked = Issue.where(project: project, is_pull_request: true, pr_review_phase: "merged", parent_issue_id: issue_ids)
              .pluck(:parent_issue_id, :updated_at)

            run_linked = AgentRun.where(project: project, goal: "create_pr", issue_id: issue_ids)
              .where.not(pull_request_number: nil)
              .joins(<<~SQL.squish)
                INNER JOIN issues merged_prs
                  ON merged_prs.project_id = agent_runs.project_id
                 AND merged_prs.github_number = agent_runs.pull_request_number
                 AND merged_prs.is_pull_request = TRUE
                 AND merged_prs.pr_review_phase = 'merged'
              SQL
              .pluck("agent_runs.issue_id", "merged_prs.updated_at")

            (linked + run_linked).each_with_object({}) do |(issue_id, updated_at), result|
              result[issue_id] = updated_at if result[issue_id].nil? || updated_at > result[issue_id]
            end
          end

          def without_open_non_pr_subissues(scope)
            scope.where(<<~SQL.squish)
              NOT EXISTS (
                SELECT 1
                FROM issues sub_issues
                WHERE sub_issues.parent_issue_id = issues.id
                  AND sub_issues.project_id = issues.project_id
                  AND sub_issues.is_pull_request = FALSE
                  AND sub_issues.github_state = 'open'
                  AND sub_issues.paid_state NOT IN ('recommend_close', 'completed')
              )
            SQL
          end

          # Returns a CASE node that maps each issue to a numeric
          # priority rank based on the project's configured priority
          # labels (+Project#effective_priority_labels+). Lower rank sorts
          # first, so P1-labeled issues beat P2/P3/unlabeled, P2 beats
          # P3/unlabeled, and P3 beats unlabeled.
          def priority_label_order_node(project)
            effective = project.effective_priority_labels
            priority_case = Arel::Nodes::Case.new
            configured_tiers = 0

            Project::PRIORITY_TIERS.each_with_index do |tier, index|
              label_name = effective[tier]
              next if label_name.blank?

              configured_tiers += 1
              condition = Arel.sql(<<~SQL.squish)
                EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements_text(issues.labels) AS label(value)
                  WHERE LOWER(label.value) = LOWER(#{Issue.connection.quote(label_name)})
                )
              SQL
              priority_case.when(condition).then(index + 1)
            end

            return Arel.sql((Project::PRIORITY_TIERS.size + 1).to_s) if configured_tiers.zero?

            priority_case.else(Project::PRIORITY_TIERS.size + 1)
          end

          # Among already-eligible issues, prefer runnable roots of a
          # dependency tree over standalone work. Count dependents across the
          # same-account local graph, not just the current project, because
          # IssueDependency supports cross-project links within an account.
          def dependency_tree_order_node
            Arel.sql(<<~SQL.squish)
              CASE WHEN EXISTS (
                SELECT 1 FROM issue_dependencies id_dep
                JOIN issues dep_issue ON dep_issue.id = id_dep.issue_id
                WHERE id_dep.depends_on_issue_id = issues.id
                  AND dep_issue.github_state = 'open'
                  AND dep_issue.is_pull_request = FALSE
              ) THEN 1 ELSE 2 END
            SQL
          end
        end
      end
    end
  end
end
