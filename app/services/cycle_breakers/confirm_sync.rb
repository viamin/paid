# frozen_string_literal: true

module CycleBreakers
  # Confirms that a repair has been synchronized by detecting that the target
  # dependency graph is now acyclic. Transitions edges from pending_sync to
  # confirmed state once the repair has been observed in the synchronized graph.
  class ConfirmSync
    Result = Data.define(:confirmed_count, :failed_count, :stale_count)

    def self.call(...) = new(...).call

    def initialize(account:)
      @account = account
    end

    # @spec AUTO-PICK-QUEUE-022
    def call
      confirmed_count = 0
      failed_count = 0
      stale_count = 0

      IssueDependency.where(repair_status: "pending_sync").find_each do |edge|
        case check_repair_status(edge)
        when :confirmed
          edge.update!(repair_status: "confirmed", repair_outcome: edge.repair_outcome.merge("confirmed_at" => Time.current))
          confirmed_count += 1
        when :failed
          handle_failed_repair(edge)
          failed_count += 1
        when :stale
          stale_count += 1
        end
      rescue StandardError => error
        Rails.logger.warn(
          message: "cycle_breaker.confirm_sync_error",
          account_id: account.id,
          edge_id: edge.id,
          error_class: error.class.name,
          error: error.message
        )
      end

      Result.new(confirmed_count: confirmed_count, failed_count: failed_count, stale_count: stale_count)
    end

    private

    attr_reader :account

    def check_repair_status(edge)
      # If the edge's issue still has a cycle, the repair hasn't taken effect yet
      cycles = Issues::DependencyCycles.call(account: account)
      return :stale if cycles.empty? # No cycles anymore, assume repair confirmed

      # Check if this edge is still involved in a cycle
      cycle_with_edge = cycles.find { |c| c.effective_edges.any? { |e| e.fetch("id") == edge.id } }
      return :confirmed unless cycle_with_edge

      # Edge is still in a cycle - check if it's exceeded retry limit
      if edge.repair_attempts >= MAX_REPAIR_ATTEMPTS
        :failed
      else
        # Still pending, not yet confirmed
        nil
      end
    end

    def handle_failed_repair(edge)
      edge.update!(
        repair_status: "failed",
        repair_outcome: edge.repair_outcome.merge(
          "failed_at" => Time.current,
          "failure_reason" => "Exceeded maximum repair attempts"
        )
      )

      Rails.logger.warn(
        message: "cycle_breaker.repair_failed",
        edge_id: edge.id,
        issue_id: edge.issue_id,
        depends_on_issue_id: edge.depends_on_issue_id,
        repair_attempts: edge.repair_attempts
      )
    end

    # Maximum number of times we'll attempt to apply a repair before giving up
    MAX_REPAIR_ATTEMPTS = 3
  end
end
