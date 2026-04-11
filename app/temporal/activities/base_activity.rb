# frozen_string_literal: true

require "temporalio/activity"

module Activities
  # Base class for all Temporal activities in this application.
  #
  # Inherits from Temporalio::Activity::Definition as per the temporalio gem v1.2.0 API.
  # Activities must implement an `execute` method which will be called by the Temporal worker.
  #
  # Temporal serializes inputs through JSON, converting symbol keys to strings.
  # InputNormalizer ensures subclasses always receive symbol-keyed hashes.
  class BaseActivity < Temporalio::Activity::Definition
    module InputNormalizer
      def execute(input)
        normalized_input = input.is_a?(Hash) ? input.deep_symbolize_keys : input

        with_rails_executor do
          with_connection_cleanup do
            super(normalized_input)
          end
        end
      end

      private

      def with_rails_executor(&block)
        executor = Rails.application.executor if defined?(Rails) && Rails.respond_to?(:application) &&
          Rails.application.respond_to?(:executor)
        return block.call unless executor

        executor.wrap(&block)
      end

      # Release any DB connection checked out during this block rather than
      # holding one for the entire activity duration. Activities often perform
      # long-running external I/O (container ops, GitHub calls) and keeping a
      # connection checked out would starve the pool.
      def with_connection_cleanup(&block)
        pool = ActiveRecord::Base.connection_pool if defined?(ActiveRecord::Base) &&
          ActiveRecord::Base.respond_to?(:connection_pool)
        return block.call unless pool

        begin
          block.call
        ensure
          pool.release_connection if pool.respond_to?(:active_connection?) && pool.active_connection?
        end
      end
    end

    def self.inherited(subclass)
      super
      subclass.prepend(InputNormalizer)
    end

    protected

    def logger
      Rails.logger
    end

    # Send a heartbeat to Temporal so the server knows this activity is still
    # alive. Safe to call frequently — the SDK throttles heartbeats internally
    # based on the configured heartbeat_timeout. Swallows calls when made
    # outside a real activity context (e.g. in tests).
    def heartbeat(*details)
      context = Temporalio::Activity::Context.current_or_nil
      return unless context

      context.heartbeat(*details)
    rescue Temporalio::Error::CanceledError
      # Allow cooperative cancellation to propagate
      raise
    end

    def update_workflow_state(workflow_id, attributes)
      WorkflowState.upsert(
        attributes.merge(temporal_workflow_id: workflow_id),
        unique_by: :temporal_workflow_id
      )
    end

    def add_phase_label(client, project, issue_number, label)
      client.add_labels_to_issue(project.full_name, issue_number, [ label ])
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.add_label_failed",
        project_id: project.id,
        pr_number: issue_number,
        label: label,
        error: e.message
      )
    end

    def record_draft_review_round_if_needed(agent_run)
      unless agent_run.count_toward_draft_review_round?
        # Defensive data-patch for legacy in-flight runs that were queued before
        # this migration deployed. Sets the tracking columns for consistency but
        # never leads to an actual increment — the terminal-status guard below
        # returns early for the same statuses this fallback targets.
        # TODO(#220): Remove after all legacy pre-migration runs have aged out.
        apply_legacy_draft_followup_fallback!(agent_run)
      end

      return unless agent_run.count_toward_draft_review_round?

      # Reload to pick up concurrent tracking-column changes (e.g. from
      # QueueAgentRunActivity#merge_draft_review_round_tracking!) and the
      # latest status. Only done for draft-round runs to skip the DB
      # round-trip for the majority of non-draft runs.
      agent_run.reload

      return unless agent_run.issue_id.present?
      if agent_run.expected_draft_review_count.blank?
        raise ArgumentError,
          "agent_run #{agent_run.id} is tracking a draft review round without expected_draft_review_count"
      end

      # Only record for successful completions (completed / no_output).
      # Now that this method is called after complete!, the status is already
      # set so this positive check reliably skips failed / cancelled / timed-out runs.
      return unless %w[completed no_output].include?(agent_run.status)

      Activities::RecordDraftReviewActivity.new.execute(
        issue_id: agent_run.issue_id,
        expected_draft_review_count: agent_run.expected_draft_review_count
      )
    end

    # Backfill tracking columns on legacy in-flight runs that reached a terminal
    # failure state before the draft-round-tracking migration deployed. This
    # write is intentional but has no downstream effect on draft_review_count:
    # the terminal-status guard in record_draft_review_round_if_needed prevents
    # the RecordDraftReviewActivity call from ever firing for these statuses.
    # TODO(#220): Remove after all legacy pre-migration runs have aged out.
    def apply_legacy_draft_followup_fallback!(agent_run)
      return if agent_run.count_toward_draft_review_round?
      return if agent_run.expected_draft_review_count.present?
      return unless agent_run.issue_id.present?
      return unless agent_run.issue&.is_pull_request?
      return unless agent_run.issue&.draft_phase?
      return unless agent_run.source_pull_request_number.present?
      return unless agent_run.trigger_type == "automatic"
      # Exclude completed runs: legacy draft followups in completed state were
      # already counted at trigger time by the unpatched RecordDraftReviewActivity
      # call. Including them here would set expected_draft_review_count to the
      # already-incremented counter, passing the idempotency guard and overcounting
      # on completion-activity retries/replays.
      return unless AgentRun::TERMINAL_FAILURE_STATUSES.include?(agent_run.status)

      # Lockless read is safe here: this fallback only targets terminal-failure
      # runs (guarded above), which never reach RecordDraftReviewActivity and
      # thus never increment draft_review_count. The value is used only for the
      # tracking-column write, not for the actual counter increment.
      expected_count = agent_run.issue.draft_review_count
      return if expected_count.blank?

      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: expected_count
      )
    end

    def track_phase(agent_run_id:, phase_key:, phase_group:, agent_run: nil, metadata: {}, started_at: Time.current)
      status = "completed"
      result = yield
      result
    rescue => e
      status = "failed"
      metadata = metadata.merge(
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(500)
      )
      raise
    ensure
      if agent_run_id.present?
        tracked_agent_run = agent_run || AgentRun.find_by(id: agent_run_id)
        record_phase(
          agent_run: tracked_agent_run,
          phase_key: phase_key,
          phase_group: phase_group,
          started_at: started_at,
          finished_at: Time.current,
          status: status,
          metadata: metadata
        )
      end
    end

    def record_phase(agent_run:, phase_key:, phase_group:, started_at:, finished_at:, status: "completed", metadata: {})
      return unless agent_run

      AgentRunPhase.record!(
        agent_run: agent_run,
        phase_key: phase_key,
        phase_group: phase_group,
        started_at: started_at,
        finished_at: finished_at,
        status: status,
        metadata: metadata
      )
    rescue => recording_error
      logger.warn(
        message: "agent_run_phase.record_failed",
        agent_run_id: agent_run.id,
        phase_key: phase_key,
        phase_group: phase_group,
        error_class: recording_error.class.name,
        error_message: recording_error.message.to_s.truncate(500)
      )
    end
  end
end
