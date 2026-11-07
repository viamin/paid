# frozen_string_literal: true

module Issues
  # RDR-081 Option B: the persisted, display-only stall projection behind the
  # partial-closeout Inbox lane. Recomputation runs the exact live machinery
  # (`Issues::StalledCloseouts`, backed by
  # `DefaultCandidateSource.partial_closeout_eligibility`) outside Inbox
  # rendering and atomically replaces the project's checkpoint and stall rows —
  # including an empty result, so "evaluated with no stalls" stays
  # distinguishable from "not evaluated yet". A failed recomputation keeps the
  # previous projection and records bounded failure metadata.
  #
  # The projection never decides admission: `eligible_scope` remains the
  # authority at continuation preflight, the dequeue recheck, and run start, and
  # a project without a successful checkpoint stays on the live path until a
  # recomputation commits.
  # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  class StalledCloseoutProjection
    FLAG = :partial_closeout_lane_read_model
    ENABLED_PROBE_TTL = 30.seconds
    FAILURE_MESSAGE_LIMIT = 500

    Result = Data.define(:success, :generation, :stalled_count, :error) do
      def success? = success
    end

    class << self
      # Rollout guard (RDR-081): default-off, per project. While off, the lane
      # keeps evaluating live admission exactly as before.
      def enabled?(project)
        enabled_project_ids([ project.id ]).include?(project.id)
      end

      # Resolves the flag for a batch of projects with the tenant overrides
      # preloaded, memoized behind a short-lived cache so write-path triggers
      # and Inbox readers do not re-resolve flipper per row.
      def enabled_project_ids(project_ids)
        ids = Array(project_ids).uniq
        return [] if ids.empty?

        Rails.cache.fetch([ "partial_closeout_lane_read_model/projects", ids.sort ], expires_in: ENABLED_PROBE_TTL) do
          Project.where(id: ids).includes(account: :tenant_setting)
            .filter_map { |project| project.id if FeatureFlags.enabled?(FLAG, project:) }
        end
      end

      # Event-driven recomputation entry point for admission-input triggers.
      # Returns false without enqueueing when the project is not enrolled.
      def schedule(project)
        return false unless enabled?(project)

        PartialCloseoutStallProjectionJob.perform_later(project.id)
        true
      end

      # Recomputes the projection outside Inbox rendering. The watermark is
      # captured before the live evaluation so a change that lands during the
      # evaluation can only leave the stored watermark older than the rows
      # (recompute-again), never newer than them (silently skipped).
      def recompute!(project)
        watermark = input_watermark(project)
        pairs = StalledCloseouts.pairs_for(project)
        replace!(project, pairs, watermark)
      rescue StandardError => error
        record_failure(project, error)
        Result.new(success: false, generation: nil, stalled_count: nil, error: error)
      end

      # True when the project needs a recomputation: no successful checkpoint
      # yet (initial backfill and enablement self-heal), or the admission-input
      # watermark drifted past the one the checkpoint recorded.
      def due?(project)
        checkpoint = PartialCloseoutStallCheckpoint.find_by(project: project)
        return true if checkpoint.nil? || !checkpoint.evaluated?

        checkpoint.input_watermark != input_watermark(project)
      end

      # Digest over the admission-relevant inputs the lane and its guards read.
      # Counts make destroys observable; max(updated_at) makes updates
      # observable. Over-inclusion is safe (extra recomputation); the digest is
      # only a drift detector, never an admission input.
      def input_watermark(project)
        project_issue_ids = Issue.where(project_id: project.id).select(:id)
        components = {
          issues: Issue.where(project_id: project.id),
          agent_runs: AgentRun.where(project_id: project.id),
          issue_continuation_requests: IssueContinuationRequest.where(project_id: project.id),
          issue_dependencies: IssueDependency.where(issue_id: project_issue_ids),
          prerequisite_notifications: Notification.where(
            account_id: project.account_id, subject_type: "Issue", subject_id: project_issue_ids
          ),
          feature_intent_issues: FeatureIntentIssue.where(issue_id: project_issue_ids),
          design_amendment_pauses: DesignAmendmentPause.where(issue_id: project_issue_ids),
          code_scanning_remediation_attempts: CodeScanningRemediationAttempt.where(issue_id: project_issue_ids),
          runners: Runner.where(user_id: project.created_by_id)
        }
        canonical = components.map { |name, scope| "#{name}=#{scope.count}=#{scope.maximum(:updated_at)&.utc&.iso8601}" }.sort.join("|")
        Digest::SHA256.hexdigest(canonical)
      end

      # The one shared reader every lane surface (list, badge, filter matrix)
      # uses, so they can never disagree about whether an issue is stalled.
      def reader_for(projects, issue_id: nil)
        Reader.new(projects, issue_id: issue_id)
      end

      private

      # One transaction: advance the checkpoint generation and replace the
      # project's stall rows, so the lane never observes new checkpoint
      # metadata with old membership.
      def replace!(project, pairs, watermark)
        now = Time.current
        ActiveRecord::Base.transaction do
          checkpoint = PartialCloseoutStallCheckpoint.create_or_find_by!(project: project)
          checkpoint.lock!
          generation = (checkpoint.generation || 0) + 1
          PartialCloseoutStall.where(project_id: project.id).delete_all
          PartialCloseoutStall.insert_all!(pairs.map { |pair| row_for(pair, generation, now) })
          checkpoint.update!(computed_at: now, generation: generation, input_watermark: watermark)
          Result.new(success: true, generation: generation, stalled_count: pairs.size, error: nil)
        end
      end

      # A failed recomputation keeps the previous checkpoint and its rows: only
      # bounded failure metadata advances, never `computed_at` or the watermark.
      def record_failure(project, error)
        checkpoint = PartialCloseoutStallCheckpoint.create_or_find_by!(project: project)
        checkpoint.update_columns(
          last_failure_at: Time.current,
          last_failure: {
            "error_class" => error.class.name,
            "message" => error.message.to_s.truncate(FAILURE_MESSAGE_LIMIT),
            "recorded_at" => Time.current.utc.iso8601
          }
        )
      rescue StandardError => failure_error
        Rails.logger.error(
          message: "partial_closeout.stall_projection_failure_recording_failed",
          project_id: project.id, error_class: failure_error.class.name
        )
        nil
      end

      def row_for(pair, generation, now)
        status = pair.status
        evidence = status.evidence
        {
          project_id: pair.issue.project_id,
          issue_id: pair.issue.id,
          evidence_digest: evidence.digest,
          status: {
            "outcome" => status.outcome,
            "reason" => status.reason,
            "admissible" => status.admissible,
            "unresolved_prerequisites" => status.unresolved_prerequisites,
            "technical_evidence" => status.technical_evidence,
            "merged_prs" => evidence.merged_prs.map do |pull_request|
              { "number" => pull_request.number, "url" => pull_request.url,
                "terminal_at" => pull_request.terminal_at&.utc&.iso8601, "run_id" => pull_request.run_id }
            end,
            "no_code_required_at" => evidence.no_code_required_at&.utc&.iso8601,
            "terminal_at" => evidence.terminal_at&.utc&.iso8601,
            "digest" => evidence.digest
          },
          blockers: status.blockers.map do |blocker|
            { "code" => blocker.code.to_s, "message" => blocker.message,
              "evidence" => blocker.evidence, "recovery" => blocker.recovery }
          end,
          projection_generation: generation,
          created_at: now,
          updated_at: now
        }
      end
    end

    # Shared projection reader for `Inbox::Queue`, `Inbox::Count`, and
    # `Inbox::Availability`. Projects enrolled in the read model with a
    # successful checkpoint are served from the persisted rows without any
    # `eligible_scope` evaluation; every other project stays on the live path.
    # @spec PARTIAL-CLOSEOUT-043
    class Reader
      def initialize(projects, issue_id: nil)
        @projects = projects
        @issue_id = issue_id
      end

      def pairs
        @pairs ||= begin
          projected = projected_pairs_by_project
          live = live_pairs.group_by { |pair| pair.issue.project_id }
          @projects.flat_map do |project|
            projected.key?(project.id) ? projected.fetch(project.id) : live.fetch(project.id, [])
          end
        end
      end

      def size
        pairs.size
      end

      def count_by_project
        pairs.each_with_object(Hash.new(0)) { |pair, counts| counts[pair.issue.project_id] += 1 }
      end

      private

      def projected_project_ids
        @projected_project_ids ||= begin
          enrolled = StalledCloseoutProjection.enabled_project_ids(@projects.map(&:id)).to_set
          evaluated = PartialCloseoutStallCheckpoint.where(project_id: enrolled.to_a).to_a
            .select(&:evaluated?).map(&:project_id)
          enrolled.intersection(evaluated.to_set)
        end
      end

      def projected_pairs_by_project
        return {} if projected_project_ids.empty?

        rows = PartialCloseoutStall.where(project_id: projected_project_ids.to_a)
        rows = rows.where(issue_id: @issue_id) if @issue_id
        rows.includes(issue: :project).order(:id).to_a
          .group_by(&:project_id)
          .transform_values { |project_rows| project_rows.map { |row| pair_for(row) } }
      end

      def live_pairs
        live_projects = @projects.reject { |project| projected_project_ids.include?(project.id) }
        return [] if live_projects.empty?

        StalledCloseouts.call(live_projects, issue_id: @issue_id)
      end

      def pair_for(row)
        StalledCloseouts::Pair.new(issue: row.issue, status: status_for(row))
      end

      # Rehydrates the persisted display state into the same
      # `CloseoutStatus::Result` shape the live path produces, so Inbox entries
      # and the detail pane render identically from either source.
      def status_for(row)
        stored = row.status
        CloseoutStatus::Result.new(
          evidence: evidence_for(stored),
          blockers: row.blockers.map { |blocker| blocker_for(blocker) },
          admissible: stored.fetch("admissible", false),
          open_request: nil,
          resolved_current_generation: false,
          outcome: stored.fetch("outcome"),
          unresolved_prerequisites: stored.fetch("unresolved_prerequisites", []),
          technical_evidence: stored.fetch("technical_evidence", [])
        )
      end

      def evidence_for(stored)
        CloseoutEvidence::Result.new(
          merged_prs: stored.fetch("merged_prs", []).map do |pull_request|
            CloseoutEvidence::MergedPullRequest.new(
              number: pull_request.fetch("number"),
              url: pull_request.fetch("url"),
              terminal_at: parse_time(pull_request["terminal_at"]),
              run_id: pull_request["run_id"]
            )
          end,
          no_code_required_at: parse_time(stored["no_code_required_at"]),
          terminal_at: parse_time(stored["terminal_at"]),
          digest: stored.fetch("digest")
        )
      end

      def blocker_for(blocker)
        CloseoutStatus::Blocker.new(
          code: blocker.fetch("code").to_sym,
          message: blocker.fetch("message"),
          evidence: blocker["evidence"],
          recovery: blocker["recovery"]
        )
      end

      def parse_time(value)
        Time.zone.parse(value) if value.present?
      end
    end
  end
end
