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

        CLOSED_PR_CORRELATED_SUBQUERY = <<~SQL.squish.freeze
          SELECT 1 FROM issues closed_prs
          WHERE closed_prs.project_id = agent_runs.project_id
            AND closed_prs.github_number = agent_runs.pull_request_number
            AND closed_prs.is_pull_request = TRUE
            AND closed_prs.github_state = 'closed'
            AND closed_prs.pr_review_phase IS DISTINCT FROM 'merged'
        SQL

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
          def eligible_for_dequeue?(project, issue_id, excluding_run_id:)
            eligible_scope(project, excluding_run_id: excluding_run_id)
              .where(id: issue_id)
              .exists?
          end

          def eligible_scope(project, excluding_run_id: nil)
            base = without_open_non_pr_subissues(base_scope(project, excluding_run_id: excluding_run_id))

            scope = base.where(paid_state: %w[new planning failed analyzed])

            recoverable_completed_issue_ids = AgentRun.where(
              project: project,
              status: "completed",
              trigger_type: "automatic",
              auto_pick: true
            ).where.not(issue_id: nil)
              .where.not(goal: "analyze_issue")
              .where(
                "agent_runs.pull_request_number IS NULL OR EXISTS (#{CLOSED_PR_CORRELATED_SUBQUERY})"
              )
              .select(:issue_id)

            pr_produced_issue_ids = AgentRun.where(
              project: project, status: "completed", goal: "create_pr"
            ).where.not(pull_request_number: nil).where.not(issue_id: nil)
              .where("NOT EXISTS (#{CLOSED_PR_CORRELATED_SUBQUERY})")
              .select(:issue_id)

            scope = scope.or(
              base.where(paid_state: "completed", id: recoverable_completed_issue_ids)
                .where.not(id: pr_produced_issue_ids)
            )

            blocked_ids = tracker_ids_blocked_by_open_references(scope, project)
            scope = scope.where.not(id: blocked_ids) if blocked_ids.present?

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
          # filters (labels, paid_state, dependencies, etc.) rather than
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

          def base_scope(project, excluding_run_id: nil)
            blocking_runs = AgentRun.where(
              project: project, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
            ).where.not(issue_id: nil)
            # At dequeue time the candidate run itself is a blocking run; ignore
            # it so the issue is not self-excluded by the "work already in
            # flight" filter (RDR-032 dequeue-time eligibility recheck).
            blocking_runs = blocking_runs.where.not(id: excluding_run_id) if excluding_run_id
            blocking_issue_ids = blocking_runs.select(:issue_id)

            base = Issue.ready_for_work(project)
              .where.not(id: blocking_issue_ids)
              .where(source: [ Issue::GITHUB_SOURCE, Issue::SYNTHETIC_CODE_SCANNING_SOURCE ])
              .where.not(id: Issue.open_pull_request_parent_issue_ids(project: project).distinct)
              # Issues abandoned because every available provider hit the per-issue
              # retry cap (#2513) are not auto-pickable until the abandonment is
              # cleared (e.g. by a successful run).
              .where(runner_retry_abandoned_at: nil)

            trusted_usernames = project.trusted_github_author_logins.presence
            if trusted_usernames
              base = base.where("LOWER(issues.github_creator_login) IN (?)", trusted_usernames)
            end

            project.effective_auto_pick_skip_labels.reduce(base) do |scope, label|
              scope.where.not("labels @> ?::jsonb", [ label ].to_json)
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
                  AND sub_issues.paid_state IS DISTINCT FROM 'recommend_close'
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
