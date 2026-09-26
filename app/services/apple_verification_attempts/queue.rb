# frozen_string_literal: true

module AppleVerificationAttempts
  # Fair, deterministic ordering of queued Apple verification attempts for the
  # single-worker scheduler. Accounts take turns, as do projects within each
  # account; attempts remain FIFO within a project.
  # @spec APPLE-ATTEMPT-003
  class Queue
    FIFO_ORDER = { created_at: :asc, id: :asc }.freeze

    def self.ordered
      account_queues = queued_attempts.group_by(&:account_id).transform_values do |attempts|
        project_queues(attempts)
      end

      round_robin(account_queues)
    end

    def self.position(attempt:)
      return nil unless attempt.status == "queued"

      ids = ordered.map(&:id)
      ids.index(attempt.id)&.+(1)
    end

    def self.depth
      AppleVerificationAttempt.where(status: "queued").count
    end

    def self.full?
      depth >= Config.max_queue_depth
    end

    def self.queued_attempts
      AppleVerificationAttempt.where(status: "queued").order(FIFO_ORDER).to_a
    end
    private_class_method :queued_attempts

    def self.project_queues(attempts)
      attempts.group_by(&:project_id).sort_by { |_project_id, queue| queue.first.slice(:created_at, :id).values }.to_h
    end
    private_class_method :project_queues

    def self.round_robin(account_queues)
      ordered_accounts = account_queues.sort_by { |_account_id, projects| projects.values.first.first.slice(:created_at, :id).values }
      interleave(ordered_accounts.map { |_account_id, projects| round_robin_projects(projects) })
    end
    private_class_method :round_robin

    def self.round_robin_projects(projects)
      interleave(projects.values)
    end
    private_class_method :round_robin_projects

    def self.interleave(queues)
      queues = queues.map(&:dup)
      [].tap do |attempts|
        until queues.empty?
          queues.each { |queue| attempts << queue.shift if queue.any? }
          queues.reject!(&:empty?)
        end
      end
    end
    private_class_method :interleave
  end
end
