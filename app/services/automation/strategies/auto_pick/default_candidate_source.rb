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
      # - Not labeled with any of {EXCLUDED_LABELS}
      # - Not a parent/tracking issue (has sub-issues), and not a tracker /
      #   meta issue whose body still references open work items
      # - Issue creator is in the project's trusted allowlist when one is
      #   configured
      #
      # Ordering rules (applied together inside one SQL query so Postgres
      # can plan efficiently):
      # - Priority label tier first (P1 > P2 > P3 > unlabeled), using each
      #   project's configured priority label names
      # - Issues in partially-complete dependency trees next
      # - Then by unblock count (how many open issues depend on this one)
      # - Finally by +github_number+ ascending (FIFO — older issues win)
      module DefaultCandidateSource
        extend CandidateSource

        # Each label here must also exist as a GitHub label in the repo so
        # it can be applied to issues.
        EXCLUDED_LABELS = %w[planning research waiting tracking epic needs-manual-setup].freeze

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

          def eligible_scope(project)
            scope = Issue.ready_for_work(project)
              .where(paid_state: %w[new planning failed])
              .where.not(id: AgentRun.where(project: project, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).where.not(issue_id: nil).select(:issue_id))
              .where(source: [ Issue::GITHUB_SOURCE, Issue::SYNTHETIC_CODE_SCANNING_SOURCE ])
              .where.not(id: Issue.where(project: project, is_pull_request: false).where.not(parent_issue_id: nil).distinct.select(:parent_issue_id))
              .where.not(id: Issue.open_pull_request_parent_issue_ids(project: project).distinct)

            trusted_usernames = Array(project.allowed_github_usernames).presence
            scope = scope.where(github_creator_login: trusted_usernames) if trusted_usernames

            scope = EXCLUDED_LABELS.reduce(scope) do |s, label|
              s.where.not("labels @> ?::jsonb", [ label ].to_json)
            end

            # Exclude tracker/meta issues that still have open referenced
            # issues. Trackers are pickable only once every issue referenced
            # in their body is closed (per collaborator feedback). The
            # ILIKE scan runs against +scope+ (not all open issues) to
            # limit query cost.
            blocked_ids = tracker_ids_blocked_by_open_references(scope, project)
            scope = scope.where.not(id: blocked_ids) if blocked_ids.present?

            scope
          end

          def next_candidate(project)
            eligible_scope(project)
              .joins(priority_joins(project))
              .order(
                Arel.sql("#{priority_label_order_sql(project)} ASC"),
                Arel.sql("COALESCE(started_trees.in_started_tree, 0) DESC"),
                Arel.sql("COALESCE(unblock_counts.unblock_count, 0) DESC"),
                Arel.sql("issues.github_number ASC")
              )
              .first
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
          # - Trackers with NO body references are conservatively blocked —
          #   they likely track work not enumerated as +#NNN+ references,
          #   and auto-picking them risks premature selection (see #615).
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
              [ issue.id, refs ]
            end
            return [] if refs_by_issue.empty?

            no_ref_ids = refs_by_issue.filter_map { |id, refs| id if refs.empty? }
            with_refs = refs_by_issue.select { |_, refs| refs.present? }
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

            blocked_with_refs = with_refs.filter_map do |issue_id, refs|
              issue_id if refs.any? do |num|
                state = referenced_states[num]
                state.nil? || state == "open"
              end
            end

            no_ref_ids + blocked_with_refs
          end

          private

          # Returns a CASE expression that maps each issue to a numeric
          # priority rank based on the project's configured priority
          # labels (+Project#effective_priority_labels+). Lower rank sorts
          # first, so P1-labeled issues beat P2/P3/unlabeled, P2 beats
          # P3/unlabeled, and P3 beats unlabeled. Label names are
          # interpolated via +connection.quote+ to keep the CASE safe
          # for use with +Arel.sql+.
          def priority_label_order_sql(project)
            effective = project.effective_priority_labels
            conn = Issue.connection
            cases = Project::PRIORITY_TIERS.each_with_index.filter_map do |tier, index|
              label_name = effective[tier]
              next if label_name.blank?

              quoted = conn.quote([ label_name ].to_json)
              "WHEN issues.labels @> #{quoted}::jsonb THEN #{index + 1}"
            end
            return (Project::PRIORITY_TIERS.size + 1).to_s if cases.empty?

            "CASE #{cases.join(' ')} ELSE #{Project::PRIORITY_TIERS.size + 1} END"
          end

          # Precomputed LEFT JOINs for priority ordering. Uses subqueries
          # evaluated once (not per-row) so Postgres can plan efficiently.
          # All project_id values are quoted via +connection.quote+ to
          # prevent SQL injection regardless of future changes to the
          # call site.
          def priority_joins(project)
            pid = Issue.connection.quote(project.id)

            <<~SQL.squish
              LEFT JOIN (#{tree_progress_subquery(pid)}) started_trees
                ON started_trees.issue_id = issues.id
              LEFT JOIN (#{unblock_count_subquery(pid)}) unblock_counts
                ON unblock_counts.issue_id = issues.id
            SQL
          end

          # Returns issue IDs that are in a "started tree": at least one
          # sibling dependency (another issue blocking the same downstream
          # issue) is already closed. Only considers in-project, non-PR,
          # open downstream issues to avoid cross-project or closed-tree
          # skew.
          def tree_progress_subquery(pid)
            <<~SQL.squish
              SELECT DISTINCT id1.depends_on_issue_id AS issue_id,
                     1 AS in_started_tree
                FROM issue_dependencies id1
               INNER JOIN issues downstream
                  ON downstream.id = id1.issue_id
                 AND downstream.github_state = 'open'
                 AND downstream.is_pull_request = FALSE
                 AND downstream.project_id = #{pid}
               INNER JOIN issue_dependencies id2
                  ON id2.issue_id = id1.issue_id
                 AND id2.depends_on_issue_id != id1.depends_on_issue_id
               INNER JOIN issues sibling
                  ON sibling.id = id2.depends_on_issue_id
                 AND sibling.github_state = 'closed'
                 AND sibling.is_pull_request = FALSE
                 AND sibling.project_id = #{pid}
            SQL
          end

          # Count of open, non-PR issues that directly depend on each
          # issue.
          def unblock_count_subquery(pid)
            <<~SQL.squish
              SELECT issue_dependencies.depends_on_issue_id AS issue_id,
                     COUNT(*) AS unblock_count
                FROM issue_dependencies
               INNER JOIN issues dep_issues
                  ON dep_issues.id = issue_dependencies.issue_id
                 AND dep_issues.github_state = 'open'
                 AND dep_issues.is_pull_request = FALSE
                 AND dep_issues.project_id = #{pid}
               GROUP BY issue_dependencies.depends_on_issue_id
            SQL
          end
        end
      end
    end
  end
end
