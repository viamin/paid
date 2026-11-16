# frozen_string_literal: true

module Issues
  # RDR-081's persisted, display-only stall read model for the
  # partial-closeout Inbox lane. Recomputation runs outside Inbox rendering,
  # asks the live admission authority (`Issues::StalledCloseouts`, backed by
  # `DefaultCandidateSource.partial_closeout_eligibility`) what is stalled,
  # and atomically replaces the project's projected rows with that answer —
  # including an empty result, so an evaluated project with no stalls is
  # distinguishable from an unevaluated one. A failed recomputation keeps the
  # previous projection and records bounded failure metadata.
  #
  # The projection never grants admission: a continuation requested from a
  # projected entry is still decided by the live scoped preflight, and the
  # dequeue recheck and run start keep their own live decisions. It never
  # mutates `paid_state`.
  # @spec PARTIAL-CLOSEOUT-042
  class StalledCloseoutProjection
    FLAG = :partial_closeout_lane_read_model

    ProjectedPullRequest = Struct.new(:number, :url, :terminal_at, :run_id, keyword_init: true)
    ProjectedEvidence = Struct.new(:merged_prs, :no_code_required_at, :terminal_at, :digest, :pr_body_revision,
      keyword_init: true) do
      def present?
        merged_prs.any? || no_code_required_at.present?
      end
    end
    ProjectedBlocker = Struct.new(:code, :message, :evidence, :recovery, keyword_init: true)
    ProjectedStatus = Struct.new(:evidence, :blockers, :admissible, :open_request, :resolved_current_generation,
      :outcome, :unresolved_prerequisites, :technical_evidence, :reason, keyword_init: true) do
      def stalled? = true

      def blocker_codes
        blockers.map(&:code)
      end
    end

    Result = Data.define(:project, :checkpoint, :success, :stall_count, :failure) do
      def success? = success
    end

    FAILURE_MESSAGE_LIMIT = 500

    class << self
      # Recomputes the project's projection from live admission and commits
      # the checkpoint plus its rows atomically. Any failure is captured on
      # the checkpoint and reported through the result; it never raises and
      # never deletes the previous rows.
      def recompute(project)
        watermark = StallProjectionInputWatermark.for(project)
        pairs = StalledCloseouts.pairs_for(project)
        checkpoint = commit_projection(project, pairs, watermark)
        log_recomputed(project, checkpoint, pairs.size)
        Result.new(project:, checkpoint:, success: true, stall_count: pairs.size, failure: nil)
      rescue StandardError => error
        checkpoint = record_failure(project, error)
        Result.new(project:, checkpoint:, success: false, stall_count: nil, failure: bounded_failure(error))
      end

      # The one shared reader for the lane list, nav badge, and filter matrix.
      # Projects on the live path (flag disabled, or no successful checkpoint
      # yet) keep the live evaluation; projects with a successful checkpoint
      # read only their persisted rows, so an Inbox render performs no
      # `eligible_scope` evaluation for them.
      # @spec PARTIAL-CLOSEOUT-043
      def pairs(projects, issue_id: nil)
        projects = tenant_projects(projects)
        return [] if projects.empty?

        checkpoints = StallProjectionCheckpoint.where(project_id: projects.map(&:id)).index_by(&:project_id)
        live_projects, projected_projects = projects.partition { |project| live?(project, checkpoints) }
        live_pairs = live_projects.empty? ? [] : StalledCloseouts.call(live_projects, issue_id:)
        projected_pairs = projected_pairs(projected_projects, issue_id)
        pairs_by_project = (live_pairs + projected_pairs).group_by { |pair| pair.issue.project_id }
        projects.flat_map { |project| pairs_by_project.fetch(project.id, []) }
      end

      # Whether the project needs a recomputation: it has no successful
      # checkpoint, or its admission-relevant inputs moved past the
      # checkpoint's watermark. Projects without a successful checkpoint are
      # always due, so a missed trigger or interrupted backfill self-heals.
      def due?(project)
        checkpoint = StallProjectionCheckpoint.find_by(project: project)
        return true if checkpoint.nil? || !checkpoint.evaluated?

        checkpoint.input_watermark != StallProjectionInputWatermark.for(project)
      end

      def enabled?(project)
        FeatureFlags.enabled?(FLAG, project:)
      end

      def schedule_recompute(project)
        RecomputeStallProjectionJob.perform_later(project.id)
      end

      private

      # Defense-in-depth alongside row-level security: the reader only ever
      # evaluates the requesting tenant's projects, so another account's
      # project can reach neither the projection rows nor the live fallback,
      # regardless of which side of the rollout a project sits on. System
      # access (recompute jobs, sweeps) reads across tenants deliberately.
      def tenant_projects(projects)
        return projects if TenantContext.bypass_enabled?

        account = Current.account
        return projects.select { |project| project.account_id == account.id } if account

        projects
      end

      def live?(project, checkpoints)
        checkpoint = checkpoints[project.id]
        return true unless enabled?(project)

        checkpoint.nil? || !checkpoint.evaluated?
      end

      def projected_pairs(projects, issue_id)
        return [] if projects.empty?

        scope = StallProjectionStall.where(project_id: projects.map(&:id))
        scope = scope.where(issue_id: issue_id) if issue_id
        rows = scope.order(:issue_id).to_a.group_by(&:project_id)
        issues = Issue.where(id: rows.values.flatten.map(&:issue_id)).index_by(&:id)
        projects.flat_map do |project|
          rows.fetch(project.id, []).filter_map do |row|
            issue = issues[row.issue_id]
            # An issue that vanished since the recomputation (closed and
            # deleted, moved projects) simply drops out until the next one.
            next unless issue

            issue.project = project
            StalledCloseouts::Pair.new(issue: issue, status: status_for(row))
          end
        end
      end

      def commit_projection(project, pairs, watermark)
        now = Time.current
        StallProjectionCheckpoint.transaction do
          checkpoint = StallProjectionCheckpoint.lock.find_or_initialize_by(project: project)
          checkpoint.account = project.account
          checkpoint.update!(computed_at: now, generation: checkpoint.generation + 1, input_watermark: watermark)
          StallProjectionStall.where(project: project).delete_all
          StallProjectionStall.insert_all!(pairs.map { |pair| row_attributes(project, checkpoint, pair, now) })
          checkpoint
        end
      end

      def record_failure(project, error)
        StallProjectionCheckpoint.transaction do
          checkpoint = StallProjectionCheckpoint.lock.find_or_initialize_by(project: project)
          checkpoint.account = project.account
          checkpoint.update!(last_failure_at: Time.current, last_failure: bounded_failure(error))
          checkpoint
        end
      rescue StandardError => failure_error
        Rails.logger.error(message: "partial_closeout.stall_projection_failure_recording_failed",
          project_id: project.id, error_class: failure_error.class.name)
        nil
      end

      def row_attributes(project, checkpoint, pair, now)
        status = pair.status
        evidence = status.evidence
        {
          account_id: project.account_id,
          project_id: project.id,
          issue_id: pair.issue.id,
          evidence_digest: evidence.digest,
          status: status.outcome,
          reason: status.reason,
          blockers: status.blockers.map do |blocker|
            { "code" => blocker.code.to_s, "message" => blocker.message, "evidence" => blocker.evidence,
              "recovery" => blocker.recovery }
          end,
          unresolved_prerequisites: status.unresolved_prerequisites,
          evidence: {
            "digest" => evidence.digest,
            "pr_body_revision" => evidence.pr_body_revision,
            "terminal_at" => evidence.terminal_at&.utc&.iso8601,
            "no_code_required_at" => evidence.no_code_required_at&.utc&.iso8601,
            "merged_prs" => evidence.merged_prs.map do |pull_request|
              { "number" => pull_request.number, "url" => pull_request.url,
                "terminal_at" => pull_request.terminal_at&.utc&.iso8601, "run_id" => pull_request.run_id }
            end
          },
          technical_evidence: status.technical_evidence,
          projection_generation: checkpoint.generation,
          created_at: now,
          updated_at: now
        }
      end

      def status_for(row)
        payload = row.evidence || {}
        ProjectedStatus.new(
          evidence: ProjectedEvidence.new(
            merged_prs: Array(payload["merged_prs"]).map do |pull_request|
              ProjectedPullRequest.new(
                number: pull_request["number"], url: pull_request["url"],
                terminal_at: parse_time(pull_request["terminal_at"]), run_id: pull_request["run_id"]
              )
            end,
            no_code_required_at: parse_time(payload["no_code_required_at"]),
            terminal_at: parse_time(payload["terminal_at"]),
            digest: payload["digest"],
            pr_body_revision: payload["pr_body_revision"]
          ),
          blockers: Array(row.blockers).map do |blocker|
            ProjectedBlocker.new(
              code: blocker["code"].to_s.presence&.to_sym, message: blocker["message"],
              evidence: blocker["evidence"], recovery: blocker["recovery"]
            )
          end,
          admissible: false,
          open_request: nil,
          resolved_current_generation: false,
          outcome: row.status,
          unresolved_prerequisites: Array(row.unresolved_prerequisites),
          technical_evidence: Array(row.technical_evidence),
          reason: row.reason
        )
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value)
      end

      def bounded_failure(error)
        { "error_class" => error.class.name, "message" => error.message.to_s.truncate(FAILURE_MESSAGE_LIMIT) }
      end

      def log_recomputed(project, checkpoint, stall_count)
        Rails.logger.info(message: "partial_closeout.stall_projection_recomputed",
          project_id: project.id, generation: checkpoint.generation, stall_count: stall_count)
      end
    end
  end
end
