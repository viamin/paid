# frozen_string_literal: true

module PartialCloseouts
  # Durable recovery state for a source-closure assessment that could not
  # complete after the agent's coding work was already pushed.
  #
  # The state lives in the agent run's reconciliation payload so it survives
  # worker restarts, container cleanup, and workflow completion. It records the
  # failed step, the pushed branch and commit, the attempt count, the sanitized
  # failure category, and the next retry or operator action.
  # @spec PARTIAL-CLOSEOUT-043
  class SourceClosureRecoveryState
    KEY = "source_closure_recovery"
    STEP = "assess_source_closure"

    WAITING = "waiting"
    RETRYING = "retrying"
    RECOVERING = "recovering"
    RECOVERED = "recovered"
    ABANDONED = "abandoned"

    PENDING_STATUSES = [ WAITING, RETRYING ].freeze
    OPEN_STATUSES = (PENDING_STATUSES + [ RECOVERING ]).freeze

    # Bounded recovery budget. Once exhausted the run stops retrying and the
    # recorded state tells the operator what is still missing.
    MAX_ATTEMPTS = 8

    # Backoff between automatic recovery attempts. The first attempts stay
    # close together (a runner outage usually clears quickly); later ones
    # back off so a long outage does not burn the budget.
    RETRY_BACKOFF = [ 5.minutes, 15.minutes, 30.minutes, 60.minutes, 2.hours, 4.hours ].freeze

    class << self
      def state(agent_run)
        agent_run.reconciliation.to_h.fetch(KEY, {}).deep_stringify_keys
      end

      def pending?(agent_run)
        PENDING_STATUSES.include?(state(agent_run)["status"])
      end

      def open?(agent_run)
        OPEN_STATUSES.include?(state(agent_run)["status"])
      end

      def exhausted?(agent_run)
        state(agent_run)["attempts"].to_i >= MAX_ATTEMPTS
      end

      # A pending recovery is due when its backoff window elapsed. Records
      # without a scheduled retry (operator-driven categories) are never due.
      def due?(agent_run, now: Time.current)
        return false unless pending?(agent_run)

        next_retry_at = state(agent_run)["next_retry_at"]
        return false if next_retry_at.blank?

        Time.iso8601(next_retry_at) <= now
      rescue ArgumentError
        true
      end

      # Records a failed assessment attempt. The attempt count grows so the
      # durable state shows how often the assessment has been tried.
      def record_attempt(agent_run, error:, branch: nil, commit_sha: nil)
        current = state(agent_run)
        attempts = current["attempts"].to_i + 1
        category = Llm::PartialCloseoutFailure.category_for(error)
        write(agent_run, current.merge(
          "status" => RETRYING,
          "step" => STEP,
          "branch" => branch || current["branch"],
          "commit_sha" => commit_sha || current["commit_sha"],
          "attempts" => attempts,
          "failure_category" => category,
          "failure_message" => message_for(error),
          "retryable" => Llm::PartialCloseoutFailure.retryable?(category),
          "next_action" => Llm::PartialCloseoutFailure.next_action_for(category),
          "updated_at" => Time.current.iso8601
        ).compact)
      end

      # Parks the run in a durable waiting state after the immediate retry
      # budget is exhausted. The next automatic attempt is scheduled with a
      # backoff; operator-action categories are never scheduled.
      def park(agent_run, error: nil, category: nil, message: nil)
        current = state(agent_run)
        resolved_category = category || current["failure_category"] || Llm::PartialCloseoutFailure.category_for(error)
        retryable = Llm::PartialCloseoutFailure.retryable?(resolved_category)
        write(agent_run, current.merge(
          "status" => WAITING,
          "step" => STEP,
          "attempts" => current["attempts"].to_i,
          "failure_category" => resolved_category,
          "failure_message" => message || message_for(error),
          "retryable" => retryable,
          "next_action" => Llm::PartialCloseoutFailure.next_action_for(resolved_category),
          "next_retry_at" => retryable ? next_retry_at_for(current["attempts"].to_i) : nil,
          "updated_at" => Time.current.iso8601
        ).compact)
      end

      # Atomically claims a pending recovery so a replayed or concurrent retry
      # cannot publish a second pull request for the same run.
      def claim(agent_run)
        payload = state(agent_run).merge(
          "status" => RECOVERING,
          "updated_at" => Time.current.iso8601
        ).to_json
        quoted = ActiveRecord::Base.connection.quote(payload)
        updated = AgentRun.where(id: agent_run.id)
          .where("reconciliation -> '#{KEY}' ->> 'status' IN (?)", PENDING_STATUSES)
          .where("COALESCE((reconciliation -> '#{KEY}' ->> 'attempts')::int, 0) < ?", MAX_ATTEMPTS)
          .update_all(Arel.sql("reconciliation = jsonb_set(reconciliation, '{#{KEY}}', #{quoted}::jsonb)"))
        agent_run.reload
        updated == 1
      end

      def recovered(agent_run, pull_request_url: nil)
        current = state(agent_run)
        write(agent_run, current.merge(
          "status" => RECOVERED,
          "next_retry_at" => nil,
          "recovered_at" => Time.current.iso8601,
          "pull_request_url" => pull_request_url,
          "updated_at" => Time.current.iso8601
        ).compact)
      end

      def abandon(agent_run, category:, message:)
        current = state(agent_run)
        write(agent_run, current.merge(
          "status" => ABANDONED,
          "failure_category" => category,
          "failure_message" => message,
          "next_action" => Llm::PartialCloseoutFailure::OPERATOR_ACTION,
          "next_retry_at" => nil,
          "updated_at" => Time.current.iso8601
        ).compact)
      end

      def next_retry_at_for(attempts)
        index = [ attempts - 1, 0 ].max
        delay = RETRY_BACKOFF[[ index, RETRY_BACKOFF.length - 1 ].min]
        (Time.current + delay).iso8601
      end

      # The scheduled next attempt as a time, or nil when no automatic retry
      # is scheduled (operator-action categories).
      def next_retry_at(agent_run)
        value = state(agent_run)["next_retry_at"]
        return nil if value.blank?

        Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      def message_for(error)
        return nil if error.nil?

        AgentRun::ErrorMessageSanitizer.call(text: error.message)
      end

      private

      def write(agent_run, payload)
        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => payload))
        payload
      end
    end
  end
end
