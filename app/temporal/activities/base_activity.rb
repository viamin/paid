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
      # Legacy fallback: if this is a draft followup that was running when the deployment happened,
      # it won't have count_toward_draft_review_round=true set. We can detect this case by checking
      # if it's a draft followup run without the new tracking columns but with expected count available.
      if !agent_run.count_toward_draft_review_round? && agent_run.expected_draft_review_count.blank?
        # Check if this looks like a legacy draft followup that should count toward review rounds
        if agent_run.issue_id.present? && agent_run.issue&.is_pull_request? &&
           agent_run.issue&.draft_phase? && agent_run.source_pull_request_number.present? &&
           agent_run.trigger_type == "automatic" && %w[completed failed cancelled timeout].include?(agent_run.status)
          # This is a legacy draft followup - treat it as if it should count
          agent_run.update!(count_toward_draft_review_round: true)
        end
      end
      return unless agent_run.count_toward_draft_review_round?
      return unless agent_run.issue_id.present?
      if agent_run.expected_draft_review_count.blank?
        raise ArgumentError,
          "agent_run #{agent_run.id} is tracking a draft review round without expected_draft_review_count"
      end

      # Only count successful runs toward draft review rounds
      # Check if we're in a successful context - this provides defense in depth
      # since the calling activities should only invoke this on successful paths
      return if agent_run.status == "failed"
      return if agent_run.status == "cancelled"
      return if agent_run.status == "timeout"

      Activities::RecordDraftReviewActivity.new.execute(
        issue_id: agent_run.issue_id,
        expected_draft_review_count: agent_run.expected_draft_review_count
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
