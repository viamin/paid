# frozen_string_literal: true

module CycleBreakers
  # Applies a recommended repair from cycle analysis to resolve a dependency cycle.
  # The repair involves removing or correcting IssueDependency edges according to
  # the cycle analysis recommendation. After applying the repair, marks the affected
  # edges as pending_sync to track confirmation once the changes are synchronized.
  class Apply
    Result = Data.define(:success, :message, :applied_edge_ids) do
      def success? = success == true
    end

    def self.call(...) = new(...).call

    def initialize(cycle:, candidate:, initiating_user:)
      @cycle = cycle
      @candidate = candidate
      @initiating_user = initiating_user
    end

    # @spec AUTO-PICK-QUEUE-021
    def call
      validate!

      changes = candidate.fetch("declaration_changes", [])
      applied_edge_ids = []

      IssueDependency.transaction do
        changes.each do |change|
          edge = edge_for_id(change.fetch("edge_id"))
          next unless edge

          case change.fetch("action")
          when "remove"
            apply_removal!(edge, applied_edge_ids)
          when "correct"
            apply_correction!(edge, change.fetch("replacement"), applied_edge_ids)
          end
        end
      end

      Result.new(success: true, message: "Repair applied and pending sync confirmation.",
        applied_edge_ids: applied_edge_ids)
    rescue StandardError => error
      Rails.logger.error(
        message: "cycle_breaker.apply_failed",
        account_id: cycle.account.id,
        cycle_occurrence: cycle.occurrence,
        error_class: error.class.name,
        error: error.message
      )
      Result.new(success: false, message: error.message, applied_edge_ids: [])
    end

    private

    attr_reader :cycle, :candidate, :initiating_user

    def validate!
      raise ArgumentError, "Candidate must have declaration_changes" unless candidate.key?("declaration_changes")
      raise ArgumentError, "Candidate declaration_changes cannot be empty" if candidate.fetch("declaration_changes").empty?
    end

    def edge_for_id(edge_id)
      cycle.effective_edges.find { |edge| edge.fetch("id") == edge_id }
    end

    def apply_removal!(edge, applied_edge_ids)
      dependency = IssueDependency.find(edge.fetch("id"))
      dependency.update!(
        repair_status: "pending_sync",
        repair_outcome: { action: "remove", applied_at: Time.current },
        repair_attempts: dependency.repair_attempts + 1,
        repair_initiated_at: dependency.repair_initiated_at || Time.current
      )
      dependency.destroy!
      applied_edge_ids << edge.fetch("id")
    end

    def apply_correction!(edge, replacement, applied_edge_ids)
      dependency = IssueDependency.find(edge.fetch("id"))
      from_issue_id = replacement.fetch("from_issue_id")
      to_issue_id = replacement.fetch("to_issue_id")

      # Update the dependency to point to the new target
      new_dependency = IssueDependency.create!(
        issue_id: from_issue_id,
        depends_on_issue_id: to_issue_id,
        repair_status: "pending_sync",
        repair_outcome: { action: "correct", original_edge_id: edge.fetch("id"), applied_at: Time.current },
        repair_attempts: 1,
        repair_initiated_at: Time.current
      )

      # Mark original as replaced
      dependency.update!(
        repair_status: "pending_sync",
        repair_outcome: { action: "correct", replaced_by_edge_id: new_dependency.id, applied_at: Time.current },
        repair_attempts: dependency.repair_attempts + 1,
        repair_initiated_at: dependency.repair_initiated_at || Time.current
      )

      applied_edge_ids << edge.fetch("id")
      applied_edge_ids << new_dependency.id
    end
  end
end
