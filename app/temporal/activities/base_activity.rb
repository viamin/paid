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
            with_tenant_context(normalized_input) do
              super(normalized_input)
            end
          end
        end
      end

      private

      def with_tenant_context(input, &block)
        account = TenantContext.with_system_access { tenant_account_from(input) }
        return TenantContext.with(account, &block) if account

        TenantContext.with_system_access(&block)
      ensure
        TenantContext.clear!
      end

      def tenant_account_from(input)
        return unless input.is_a?(Hash)

        return account_from_id(input[:account_id]) if input[:account_id]
        return project_from_id(input[:project_id])&.account if input[:project_id]
        return agent_run_from_id(input[:agent_run_id])&.project&.account if input[:agent_run_id]
        issue_from_id(input[:issue_id])&.project&.account if input[:issue_id]
      end

      def account_from_id(account_id)
        Account.find_by(id: account_id) if defined?(Account) && Account.respond_to?(:find_by)
      end

      def project_from_id(project_id)
        Project.find_by(id: project_id) if defined?(Project) && Project.respond_to?(:find_by)
      end

      def agent_run_from_id(agent_run_id)
        return unless defined?(AgentRun) && AgentRun.respond_to?(:includes)

        AgentRun.includes(:project).find_by(id: agent_run_id)
      end

      def issue_from_id(issue_id)
        return unless defined?(Issue) && Issue.respond_to?(:includes)

        Issue.includes(project: :account).find_by(id: issue_id)
      end

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

    def feature_enabled?(flag_name, project: nil)
      FeatureFlags.enabled?(flag_name, project:)
    end

    # Raises a retryable Temporal error when the GitHub API rate limit is
    # near exhaustion. Call this before making API requests so polling
    # activities stop early and let the next cycle handle remaining work.
    #
    # Uses GithubClient#rate_limit_remaining! (which raises on Octokit
    # errors instead of returning 0) so that auth/transport failures are
    # not misclassified as rate-limit exhaustion. On probe failure we log
    # a warning and return, letting the real API call surface the actual error.
    # threshold default of 10 matches GithubClient#rate_limit_low? — if the
    # budget floor changes, update both to keep them consistent.
    def check_rate_budget!(client, threshold: 10)
      remaining = client.rate_limit_remaining!
    rescue Octokit::Error => e
      logger.warn(
        message: "rate_limit.probe_failed",
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    else
      return unless remaining < threshold

      logger.warn(
        message: "rate_limit.budget_low",
        remaining: remaining
      )

      raise Temporalio::Error::ApplicationError.new(
        "GitHub API rate limit budget low (remaining: #{remaining})",
        type: "RateLimit"
      )
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

    def record_cross_repo_issue(agent_run, repo, gh_issue, role:)
      entry = {
        "repo" => repo,
        "issue_number" => gh_issue.number,
        "issue_url" => gh_issue.html_url,
        "role" => role
      }
      # Atomic append to avoid lost updates if called concurrently on the same agent_run
      AgentRun.where(id: agent_run.id).update_all(
        Arel.sql(<<~SQL.squish)
          cross_repo_issues = COALESCE(cross_repo_issues, '[]'::jsonb) || #{ActiveRecord::Base.connection.quote(entry.to_json)}::jsonb
        SQL
      )
      agent_run.reload
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
