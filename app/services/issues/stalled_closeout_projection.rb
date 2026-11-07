# frozen_string_literal: true

module Issues
  # Display-only read model for the partial_closeout Inbox lane (RDR-081,
  # #4558/#4912), shipped behind the default-off
  # `partial_closeout_lane_read_model` feature flag.
  #
  # Recomputation runs the authoritative live admission computation
  # (`Issues::StalledCloseouts`, backed by
  # `DefaultCandidateSource.eligible_scope` and `CloseoutStatus`) outside
  # Inbox rendering and atomically persists it: one project checkpoint per
  # successful recomputation — including an empty result — plus one row per
  # stalled issue carrying the serialized display payload.
  #
  # The projection is a read model, never a second admission authority: it
  # never grants a continuation and never mutates `paid_state`.
  # `Issues::RequestContinuation` still preflights and the dequeue recheck
  # still re-applies the live scoped admission decision, so a stale row can
  # cost an operator a click but can never schedule unauthorized work.
  # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  class StalledCloseoutProjection
    FLAG = :partial_closeout_lane_read_model
    FAILURE_MESSAGE_LIMIT = 500
    PROJECT_ACTOR_PREFIX = "Project;"

    RecomputeResult = Data.define(:project_id, :generation, :stall_count)

    class << self
      # ---- rollout guard -------------------------------------------------

      def enabled?(project)
        resolve_enabled([ project ]).include?(project)
      end

      # Enqueues a recomputation for a flag-enabled project. Flag-off projects
      # stay on the live path, so the enqueue cost is paid only where the read
      # model is in force.
      def schedule(project)
        return unless enabled?(project)

        RecomputeStalledCloseoutProjectionJob.perform_later(project.id)
      end

      # Batch flag resolution with one Flipper gate read, mirroring
      # `FeatureFlags.enabled?` precedence: tenant override, then boolean
      # gate, then per-project actor gates.
      def resolve_enabled(projects)
        status = FeatureFlags.rollout_status(FLAG)
        actor_ids = status[:actors].grep(/\A#{PROJECT_ACTOR_PREFIX}/)
          .map { |actor| actor.delete_prefix(PROJECT_ACTOR_PREFIX).to_i }.to_set

        projects.select do |project|
          tenant_value = project.account.tenant_setting&.features
            .then { |features| features.is_a?(Hash) ? features[FLAG.to_s] : nil }
          next tenant_value == true if [ true, false ].include?(tenant_value)
          next true if status[:boolean]

          actor_ids.include?(project.id)
        end
      end

      # ---- shared read path ----------------------------------------------

      # Returns `Issues::StalledCloseouts::Pair` records for the given
      # projects. A flag-enabled project with a successful checkpoint reads
      # its persisted rows and evaluates no `eligible_scope`; every other
      # project (flag off, or no successful checkpoint yet) stays on the live
      # path, so the three Inbox consumers can never disagree about where a
      # project's membership comes from.
      # @spec PARTIAL-CLOSEOUT-043
      def read(projects, issue_id: nil)
        return [] if projects.empty?

        projected, live = partition(projects)
        projected_pairs(projected, issue_id:) + Issues::StalledCloseouts.call(live, issue_id:)
      end

      def partition(projects)
        enabled = resolve_enabled(projects)
        return [ [], projects ] if enabled.empty?

        checkpoints = PartialCloseoutStallCheckpoint.where(project_id: enabled.map(&:id)).index_by(&:project_id)
        projected = enabled.select { |project| checkpoints[project.id]&.successful? }
        [ projected, projects - projected ]
      end

      # Materializes the persisted rows back into live-shaped
      # `CloseoutStatus::Result` payloads so the Inbox list and detail views
      # render exactly what the live lane would.
      def projected_pairs(projects, issue_id:)
        return [] if projects.empty?

        stalls = PartialCloseoutStall.where(project_id: projects.map(&:id))
        stalls = stalls.where(issue_id: issue_id) if issue_id
        rows = stalls.order(:issue_id).to_a
        return [] if rows.empty?

        issues_by_id = Issue.where(id: rows.map(&:issue_id)).index_by(&:id)
        projects_by_id = projects.index_by(&:id)
        rows.filter_map do |stall|
          issue = issues_by_id[stall.issue_id]
          next unless issue

          # Reuse the caller's loaded projects (Queue/Count/Availability
          # preload account settings on them) instead of refetching.
          issue.project = projects_by_id.fetch(issue.project_id)
          StalledCloseouts::Pair.new(issue: issue, status: materialize_status(stall))
        end
      end

      # ---- recomputation -------------------------------------------------

      # Recomputes the projection from live admission outside Inbox
      # rendering. The watermark is captured before the reads so any input
      # committed during or after the computation reads as newer and keeps
      # the project due for the next sweep — the sweep can recompute
      # redundantly, never miss an input.
      # @spec PARTIAL-CLOSEOUT-042
      def recompute(project)
        watermark = Time.current
        pairs = Issues::StalledCloseouts.call([ project ])
        commit(project, pairs, watermark)
      rescue StandardError => error
        record_failure(project, error)
        raise
      end

      def commit(project, pairs, watermark)
        rows = pairs.map { |pair| stall_attributes(project, pair) }
        project.account.transaction do
          checkpoint = checkpoint_with_lock(project)
          generation = checkpoint.generation + 1
          rows.each { |row| row[:projection_generation] = generation }
          # Atomic replacement: a project with no stall keeps a successful
          # checkpoint and zero child rows; a stale row is removed by the
          # recomputation that supersedes it.
          PartialCloseoutStall.where(project: project).delete_all
          PartialCloseoutStall.insert_all!(rows) if rows.any?
          checkpoint.update!(
            generation: generation,
            computed_at: watermark,
            input_watermark: watermark,
            last_failure_at: nil,
            last_failure: {}
          )
          RecomputeResult.new(project_id: project.id, generation: generation, stall_count: rows.size)
        end
      end

      # ---- sweep -----------------------------------------------------------

      # Flag-enabled projects of `account` whose projection is due: no
      # successful checkpoint (always due, so a missed trigger or interrupted
      # initial backfill self-heals), or an admission-relevant input changed
      # after the checkpoint's watermark.
      def due_projects(account)
        projects = resolve_enabled(account.projects.active.to_a)
        return [] if projects.empty?

        checkpoints = PartialCloseoutStallCheckpoint.where(project_id: projects.map(&:id)).index_by(&:project_id)
        evaluated, unevaluated = projects.partition do |project|
          checkpoints[project.id]&.successful? && checkpoints[project.id].input_watermark.present?
        end
        return projects if evaluated.empty?

        fresh_ids = fresh_project_ids(account, evaluated)
        unevaluated + evaluated.reject { |project| fresh_ids.include?(project.id) }
      end

      private

      # Evaluated projects with NO admission-relevant input newer than their
      # checkpoint watermark. The EXISTS list mirrors the inputs the live
      # computation reads (issues, runs and their model selections,
      # continuation requests, dependency edges in both directions,
      # feature-intent links, scanner attempts, design-amendment holds,
      # prerequisite notifications) plus the account-level inputs that change
      # tier feasibility (runners/providers) and the shared model catalog.
      def fresh_project_ids(account, evaluated)
        return [].to_set if evaluated.empty?

        ids = evaluated.map(&:id)
        due_ids = PartialCloseoutStallCheckpoint.connection.select_values(<<~SQL.squish, "stall projection due")
          SELECT DISTINCT c.project_id
          FROM partial_closeout_stall_checkpoints c
          WHERE c.project_id IN (#{ids.join(",")})
            AND c.computed_at IS NOT NULL
            AND c.input_watermark IS NOT NULL
            AND (
              EXISTS (SELECT 1 FROM issues i WHERE i.project_id = c.project_id AND i.updated_at > c.input_watermark)
              OR EXISTS (SELECT 1 FROM agent_runs r WHERE r.project_id = c.project_id AND r.updated_at > c.input_watermark)
              OR EXISTS (
                SELECT 1 FROM model_selections ms
                INNER JOIN agent_runs ms_runs ON ms_runs.id = ms.agent_run_id
                WHERE ms_runs.project_id = c.project_id AND ms.created_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM issue_continuation_requests cr
                WHERE cr.project_id = c.project_id AND cr.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM issue_dependencies d
                INNER JOIN issues d_issues ON d_issues.id = d.issue_id
                WHERE d_issues.project_id = c.project_id AND d.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM issue_dependencies dd
                INNER JOIN issues dd_issues ON dd_issues.id = dd.depends_on_issue_id
                WHERE dd_issues.project_id = c.project_id AND dd.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM feature_intent_issues fi
                INNER JOIN issues fi_issues ON fi_issues.id = fi.issue_id
                WHERE fi_issues.project_id = c.project_id AND fi.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM code_scanning_remediation_attempts cs
                INNER JOIN issues cs_issues ON cs_issues.id = cs.issue_id
                WHERE cs_issues.project_id = c.project_id AND cs.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM design_amendment_pauses dp
                INNER JOIN issues dp_issues ON dp_issues.id = dp.issue_id
                WHERE dp_issues.project_id = c.project_id AND dp.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM notifications n
                INNER JOIN issues n_issues ON n_issues.id = n.subject_id AND n.subject_type = 'Issue'
                WHERE n.account_id = #{account.id}
                  AND n_issues.project_id = c.project_id
                  AND n.updated_at > c.input_watermark
              )
              OR EXISTS (
                SELECT 1 FROM runners sweep_runners
                INNER JOIN users sweep_users ON sweep_users.id = sweep_runners.user_id
                WHERE sweep_users.account_id = #{account.id}
                  AND sweep_runners.updated_at > c.input_watermark
              )
              OR EXISTS (SELECT 1 FROM llm_models lm WHERE lm.updated_at > c.input_watermark)
            )
        SQL
        evaluated.map(&:id).to_set - due_ids.map(&:to_i).to_set
      end

      def checkpoint_with_lock(project)
        # create_or_find_by! tolerates the unique-index race; the row lock
        # then serializes concurrent recomputations so generation numbering
        # and row replacement stay atomic per project.
        checkpoint = PartialCloseoutStallCheckpoint.create_or_find_by!(account: project.account, project: project)
        PartialCloseoutStallCheckpoint.lock.find(checkpoint.id)
      end

      def stall_attributes(project, pair)
        status = pair.status
        now = Time.current
        {
          account_id: project.account_id,
          project_id: project.id,
          issue_id: pair.issue.id,
          evidence_digest: status.evidence.digest,
          status: serialize_status(status),
          blockers: serialize_blockers(status.blockers),
          created_at: now,
          updated_at: now
        }
      end

      def serialize_status(status)
        evidence = status.evidence
        {
          "outcome" => status.outcome,
          "reason" => status.reason,
          "unresolved_prerequisites" => status.unresolved_prerequisites,
          "evidence" => {
            "merged_prs" => evidence.merged_prs.map do |pr|
              { "number" => pr.number, "url" => pr.url,
                "terminal_at" => pr.terminal_at&.utc&.iso8601, "run_id" => pr.run_id }
            end,
            "no_code_required_at" => evidence.no_code_required_at&.utc&.iso8601,
            "terminal_at" => evidence.terminal_at&.utc&.iso8601,
            "digest" => evidence.digest
          },
          "technical_evidence" => status.technical_evidence
        }
      end

      def serialize_blockers(blockers)
        blockers.map do |blocker|
          { "code" => blocker.code.to_s, "message" => blocker.message,
            "evidence" => blocker.evidence, "recovery" => blocker.recovery }
        end
      end

      def materialize_status(stall)
        payload = stall.status
        evidence = payload.fetch("evidence", {})
        CloseoutStatus::Result.new(
          evidence: CloseoutEvidence::Result.new(
            merged_prs: (evidence["merged_prs"] || []).map do |pr|
              CloseoutEvidence::MergedPullRequest.new(
                number: pr["number"], url: pr["url"],
                terminal_at: parse_time(pr["terminal_at"]), run_id: pr["run_id"]
              )
            end,
            no_code_required_at: parse_time(evidence["no_code_required_at"]),
            terminal_at: parse_time(evidence["terminal_at"]),
            digest: evidence["digest"]
          ),
          blockers: stall.blockers.map do |blocker|
            CloseoutStatus::Blocker.new(
              code: blocker["code"].to_s.to_sym,
              message: blocker["message"],
              evidence: blocker["evidence"],
              recovery: blocker["recovery"]
            )
          end,
          # A projected row only exists for a stall the live computation held:
          # not admissible, no open request, not resolved against its
          # generation. The live preflight re-derives all three at action time.
          admissible: false,
          open_request: nil,
          resolved_current_generation: false,
          outcome: payload["outcome"],
          unresolved_prerequisites: payload["unresolved_prerequisites"] || [],
          technical_evidence: payload["technical_evidence"] || []
        )
      end

      def parse_time(value)
        Time.iso8601(value) if value.present?
      end

      # Records bounded failure metadata without deleting rows or advancing
      # computed_at / input_watermark; the previous projection stays served.
      def record_failure(project, error)
        PartialCloseoutStallCheckpoint.create_or_find_by!(account: project.account, project: project)
          .update!(last_failure_at: Time.current, last_failure: bounded_failure(error))
      rescue StandardError => failure_error
        Rails.logger.error(
          message: "issues.stall_projection_failure_metadata_failed",
          project_id: project.id,
          error_class: failure_error.class.name
        )
      end

      def bounded_failure(error)
        {
          "error_class" => error.class.name,
          "message" => error.message.to_s[0, FAILURE_MESSAGE_LIMIT],
          "recorded_at" => Time.current.utc.iso8601
        }
      end
    end
  end
end
