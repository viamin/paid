# frozen_string_literal: true

module Issues
  # RDR-081 Option B (#4912): the persisted, display-only stall projection
  # the partial-closeout Inbox lane reads instead of evaluating live
  # admission on the request path.
  #
  # This is a read model, never a second admission authority: recomputation
  # runs outside Inbox rendering (job + sweep), records what the live
  # `Issues::StalledCloseouts` evaluation observed — including an empty
  # result — and every operator action from a projected entry is still
  # decided by the live scoped continuation preflight and dequeue recheck.
  # A project reads the projection only while its rollout guard is enabled
  # and its checkpoint has committed; anything else stays on the live path.
  # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  class StalledCloseoutProjection
    FLAG = :partial_closeout_lane_read_model
    FAILURE_MESSAGE_LIMIT = 500

    Result = Struct.new(:success, :error, keyword_init: true) do
      def success? = success
    end

    class << self
      def enabled?(project)
        FeatureFlags.enabled?(FLAG, project:)
      end

      # The one shared reader for Inbox::Queue, Inbox::Count, and
      # Inbox::Availability, so the lane list, the nav badge, and the filter
      # matrix can never disagree about whether an issue is stalled. A
      # rollout-enabled project with a successful checkpoint performs no
      # `eligible_scope` evaluation; every other project falls back to the
      # live path.
      # @spec PARTIAL-CLOSEOUT-043
      def pairs_for(projects, issue_id: nil)
        return [] if projects.empty?

        enabled = projects.select { |project| enabled?(project) }
        return Issues::StalledCloseouts.call(projects, issue_id: issue_id) if enabled.empty?

        checks = StalledCloseoutProjectionCheck.where(project_id: enabled.map(&:id))
          .where.not(computed_at: nil).index_by(&:project_id)
        projected = enabled.select { |project| checks.key?(project.id) }
        # Initial flag enablement schedules the recomputation before the
        # project switches to projection reads; until its checkpoint
        # commits it stays on the live path.
        (enabled - projected).each { |project| bootstrap(project) }

        projected_pairs(projected, checks, issue_id: issue_id) +
          Issues::StalledCloseouts.call(projects - projected, issue_id: issue_id)
      end

      # Recomputes one project's projection off the request path and
      # atomically replaces its stalled-issue rows with the checkpoint
      # advance in a single transaction. A failure keeps the previous rows
      # and checkpoint and records bounded failure metadata instead.
      # @spec PARTIAL-CLOSEOUT-042
      def recompute(project)
        pairs = Issues::StalledCloseouts.pairs_for(project)
        watermark = input_watermark(project)
        before = membership_fingerprint(project.id)

        StalledCloseoutProjectionCheck.create_or_find_by(project: project)
        ActiveRecord::Base.transaction do
          check = StalledCloseoutProjectionCheck.lock.find_by!(project: project)
          StalledCloseoutProjectionRow.where(project_id: project.id).delete_all
          generation = check.generation + 1
          insert_rows(project, generation, pairs)
          check.update!(
            generation: generation,
            computed_at: Time.current,
            input_watermark: watermark
          )
        end

        bump_inbox_cache(project) if before != membership_fingerprint(project.id)
        log_recomputed(project, pairs.size)
        Result.new(success: true)
      rescue StandardError => e
        record_failure(project, e)
        Result.new(success: false, error: e)
      end

      # The newest admission-relevant input for the project. Any change to
      # lane membership or admission moves one of these `updated_at`
      # columns past the checkpoint watermark, so the sweep (and therefore
      # a missed trigger) self-heals instead of stranding a stall. The
      # project's own timestamp is read from the database — an in-memory
      # association can be stale next to the `after_commit` writes other
      # models make on this row.
      def input_watermark(project)
        issue_ids = Issue.where(project_id: project.id).select(:id)
        [
          Project.where(id: project.id).pick(:updated_at),
          Issue.where(project_id: project.id).maximum(:updated_at),
          AgentRun.where(project_id: project.id).maximum(:updated_at),
          IssueContinuationRequest.where(project_id: project.id).maximum(:updated_at),
          FeatureIntent.where(project_id: project.id).maximum(:updated_at),
          FeatureIntentIssue.where(issue_id: issue_ids).maximum(:updated_at),
          DesignAmendmentPause.where(issue_id: issue_ids).maximum(:updated_at),
          CodeScanningRemediationAttempt.where(issue_id: issue_ids).maximum(:updated_at),
          IssueDependency.where(issue_id: issue_ids).maximum(:updated_at),
          Notification.where(account_id: project.account_id).maximum(:updated_at),
          Runner.where(user_id: project.created_by_id).maximum(:updated_at),
          ModelSelection.joins(:agent_run).where(agent_runs: { project_id: project.id }).maximum(:created_at)
        ].compact.max
      end

      # Projects without a successful checkpoint are always due, so
      # interrupted initial backfill or checkpoint loss heals on the next
      # sweep rather than stranding a stall.
      def due?(project)
        check = StalledCloseoutProjectionCheck.find_by(project_id: project.id)
        return true unless check&.evaluated?

        current = input_watermark(project)
        current.present? && (check.input_watermark.nil? || current > check.input_watermark)
      end

      # Enqueues an off-request-path recomputation for a rollout-enabled
      # project. Deliberately a no-op while the guard is disabled, so the
      # model callbacks that call it stay cheap.
      def schedule(project)
        return unless enabled?(project)

        RecomputeStalledCloseoutProjectionJob.perform_later(project.id)
      end

      private

      # A scheduling hiccup must never break an Inbox render; the sweep
      # rediscovers un-checkpointed projects on its own.
      def bootstrap(project)
        schedule(project)
      rescue StandardError => e
        Rails.logger.warn(
          message: "issues.stalled_closeout_projection_bootstrap_failed",
          project_id: project.id,
          error_class: e.class.name
        )
      end

      def projected_pairs(projected, checks, issue_id:)
        scope = StalledCloseoutProjectionRow.where(
          project_id: projected.map(&:id),
          projection_generation: projected.map { |project| checks.fetch(project.id).generation }
        )
        scope = scope.where(issue_id: issue_id) if issue_id
        rows = scope.order(:issue_id).to_a
        return [] if rows.empty?

        issues = Issue.where(id: rows.map(&:issue_id)).includes(:project).index_by(&:id)
        rows.filter_map do |row|
          issue = issues[row.issue_id]
          # A row whose issue vanished mid-flight is replaced by the next
          # recomputation; never render a dangling projection.
          next unless issue

          StalledCloseouts::Pair.new(issue: issue, status: row.status_result)
        end
      end

      def insert_rows(project, generation, pairs)
        return if pairs.empty?

        now = Time.current
        StalledCloseoutProjectionRow.insert_all!(pairs.map do |pair|
          {
            "project_id" => project.id,
            "issue_id" => pair.issue.id,
            "evidence_digest" => pair.status.evidence.digest,
            "status" => serialize_status(pair.status),
            "blockers" => pair.status.blockers.map { |blocker| serialize_blocker(blocker) },
            "projection_generation" => generation,
            "created_at" => now,
            "updated_at" => now
          }
        end)
      end

      def serialize_status(status)
        {
          "evidence" => {
            "merged_prs" => status.evidence.merged_prs.map do |pr|
              { "number" => pr.number, "url" => pr.url, "terminal_at" => serialize_time(pr.terminal_at),
                "run_id" => pr.run_id, "body_digest" => pr.body_digest }
            end,
            "no_code_required_at" => serialize_time(status.evidence.no_code_required_at),
            "terminal_at" => serialize_time(status.evidence.terminal_at),
            "digest" => status.evidence.digest,
            "pr_body_revision" => status.evidence.pr_body_revision
          },
          "admissible" => status.admissible,
          "resolved_current_generation" => status.resolved_current_generation,
          "outcome" => status.outcome,
          "unresolved_prerequisites" => status.unresolved_prerequisites,
          "technical_evidence" => status.technical_evidence
        }
      end

      def serialize_blocker(blocker)
        {
          "code" => blocker.code&.to_s,
          "message" => blocker.message,
          "evidence" => blocker.evidence,
          "recovery" => blocker.recovery
        }
      end

      def serialize_time(value)
        value&.utc&.iso8601
      end

      def membership_fingerprint(project_id)
        StalledCloseoutProjectionRow.where(project_id: project_id).order(:issue_id)
          .pluck(:issue_id, :evidence_digest).flatten.join("|")
      end

      def bump_inbox_cache(project)
        Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      end

      def record_failure(project, error)
        check = StalledCloseoutProjectionCheck.find_or_initialize_by(project: project)
        check.last_failure_at = Time.current
        check.last_failure = {
          "error_class" => error.class.name,
          "message" => error.message.to_s[0, FAILURE_MESSAGE_LIMIT],
          "failed_at" => Time.current.utc.iso8601
        }
        check.save!
        Rails.logger.error(
          message: "issues.stalled_closeout_projection_recompute_failed",
          project_id: project.id,
          error_class: error.class.name,
          error: error.message
        )
      rescue StandardError => e
        Rails.logger.error(
          message: "issues.stalled_closeout_projection_failure_record_failed",
          project_id: project.id,
          error_class: e.class.name,
          error: e.message
        )
      end

      def log_recomputed(project, rows)
        Rails.logger.info(
          message: "issues.stalled_closeout_projection_recomputed",
          project_id: project.id,
          stalled_issues: rows
        )
      end
    end
  end
end
