# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-003
  # Fair-share queue for Apple verification attempts. The first deployment
  # allows exactly one active Apple verification VM, so every additional
  # attempt waits in line. The queue is ordered so a backlog from a single
  # account or project cannot starve other accounts: between accounts we
  # round-robin, and within an account we round-robin between projects,
  # keeping each project's attempts in FIFO order so the oldest queued
  # attempt of a project goes first.
  class Queue
    Entry = Data.define(:attempt, :position, :account_id, :project_id)

    DEFAULT_QUEUE_DEPTH = 25
    DEFAULT_MAX_ATTEMPTS_PER_RUN = 5
    DEFAULT_MAX_RUNTIME_MINUTES = 45
    DEFAULT_RETAINED_STORAGE_HOURS = 1

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      account_scope: nil,
      project_scope: nil,
      attempt_scope: AppleVerificationAttempt,
      queue_depth_limit: DEFAULT_QUEUE_DEPTH,
      max_attempts_per_run: DEFAULT_MAX_ATTEMPTS_PER_RUN,
      max_runtime_minutes: DEFAULT_MAX_RUNTIME_MINUTES,
      retained_storage_hours: DEFAULT_RETAINED_STORAGE_HOURS,
      clock: Time
    )
      @account_scope = account_scope
      @project_scope = project_scope
      @attempt_scope = attempt_scope
      @queue_depth_limit = queue_depth_limit
      @max_attempts_per_run = max_attempts_per_run
      @max_runtime_minutes = max_runtime_minutes
      @retained_storage_hours = retained_storage_hours
      @clock = clock
    end

    # Returns the fair-share ordered queue of waiting attempts, each with a
    # 1-based position. Attempts already running or terminal are excluded.
    def call
      queued = queued_relation.order(:created_at).to_a
      return [] if queued.empty?

      ordered = interleave(queued)
      annotate_positions(ordered)
    end

    # Returns the 1-based position of +attempt+ in the fair-share queue, or
    # +nil+ if the attempt is not currently queued (terminal, running, or
    # not found). The position is computed against the same ordered snapshot
    # the rest of the queue uses.
    def position_for(attempt)
      entries = call
      entry = entries.find { |entry| entry.attempt.id == attempt.id }
      entry&.position
    end

    # Cancels a queued attempt in place. A non-queued attempt raises
    # {NotQueuedError}; the underlying +AppleVerificationAttempts::Cancel+
    # service owns the lifecycle transition, this method only enforces that
    # the attempt is still waiting in line.
    def cancel(attempt)
      raise NotQueuedError, "attempt is not in the queue" unless attempt.status == "queued"

      AppleVerificationAttempts::Cancel.call(attempt: attempt)
    end

    def queue_depth_limit = @queue_depth_limit
    def max_attempts_per_run = @max_attempts_per_run
    def max_runtime_minutes = @max_runtime_minutes
    def retained_storage_hours = @retained_storage_hours

    def self.limits_for(
      queue_depth_limit: DEFAULT_QUEUE_DEPTH,
      max_attempts_per_run: DEFAULT_MAX_ATTEMPTS_PER_RUN,
      max_runtime_minutes: DEFAULT_MAX_RUNTIME_MINUTES,
      retained_storage_hours: DEFAULT_RETAINED_STORAGE_HOURS
    )
      {
        queue_depth_limit:,
        max_attempts_per_run:,
        max_runtime_minutes:,
        retained_storage_hours:
      }
    end

    NotQueuedError = Class.new(ArgumentError)

    private

    attr_reader :attempt_scope, :clock

    def queued_relation
      relation = attempt_scope.queued
      relation = relation.for_account(@account_scope) if @account_scope
      relation = relation.for_project(@project_scope) if @project_scope
      relation
    end

    # Groups queued attempts by (account_id, project_id) preserving FIFO
    # within each project, then interleaves projects round-robin. The
    # interleave walks the (account, project) pairs in the order they first
    # appear in the snapshot so projects that queued earliest get a turn
    # first, but every project gets a turn before any project sees a second
    # attempt.
    def interleave(attempts)
      grouped = attempts.group_by { |attempt| [ attempt.account_id, attempt.project_id ] }
      ordering = grouped.keys
      queues = grouped.transform_values { |entries| entries.dup }

      interleaved = []
      loop do
        progressed = false
        ordering.each do |key|
          next if queues[key].empty?

          interleaved << queues[key].shift
          progressed = true
        end
        break unless progressed
      end
      interleaved
    end

    def annotate_positions(attempts)
      attempts.each_with_index.map do |attempt, index|
        Entry.new(attempt:, position: index + 1, account_id: attempt.account_id, project_id: attempt.project_id)
      end
    end
  end
end
