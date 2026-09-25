# frozen_string_literal: true

module AppleVerificationAttempts
  # Fair, deterministic ordering of queued Apple verification attempts for the
  # single-worker scheduler: grouped by tenant and project, FIFO within a group.
  # @spec APPLE-ATTEMPT-003
  class Queue
    ORDER = { account_id: :asc, project_id: :asc, created_at: :asc, id: :asc }.freeze

    def self.ordered
      AppleVerificationAttempt.where(status: "queued").order(ORDER)
    end

    def self.position(attempt:)
      return nil unless attempt.status == "queued"

      ids = ordered.pluck(:id)
      ids.index(attempt.id)&.+(1)
    end

    def self.depth
      ordered.count
    end

    def self.full?
      depth >= Config.max_queue_depth
    end
  end
end
