# frozen_string_literal: true

module WorkerSettings
  # Normalizes the GoodJob queue string (`name:threads;name:threads`).
  #
  # A tenant can persist its own `good_job_queues` override, and that override
  # wins over the deployment environment. Without normalization such an
  # override silently drops queues the platform requires — for example
  # `shadow_evaluation`, which serves the long-running reviewer evaluations —
  # leaving the matching jobs queued with no worker to run them.
  #
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  class GoodJobQueues
    # Queues the platform requires to be served, with their minimum threads.
    REQUIRED = { "shadow_evaluation" => 1 }.freeze
    # Highest priority first. Reconciliation reclaims threads from the end.
    PRIORITY = %w[default maintenance metrics knowledge low_priority shadow_evaluation].freeze

    class << self
      # Ensure the required queues are served without changing any other
      # allocation. Unparseable values are returned untouched so model
      # validation can report them.
      def normalize(value)
        queues = parse(value)
        return value if queues.nil?

        serialize(with_required_queues(queues))
      end

      # Ensure the required queues are served and the per-queue thread
      # allocation fits the pool budget, reclaiming threads from the
      # lowest-priority queues first.
      def reconcile(value, max_threads:)
        queues = parse(value)
        return value if queues.nil?

        reconciled = trim_to_budget(with_required_queues(queues), max_threads)
        warn_over_budget(reconciled, max_threads)
        serialize(reconciled)
      end

      # Parsed queues as `name => threads`, or nil when the value is not a
      # well-formed queue string.
      def parse(value)
        entries = value.to_s.split(";").map(&:strip).reject(&:empty?)
        return nil if entries.empty?

        entries.each_with_object({}) do |entry, queues|
          name, threads = entry.split(":", 2)
          count = Integer(threads.to_s, exception: false)
          return nil if name.to_s.strip.empty? || count.nil? || count.negative?

          queues[name.strip] = count
        end
      end

      private

      def with_required_queues(queues)
        REQUIRED.each_with_object(queues.dup) do |(name, threads), result|
          result[name] = [ result.fetch(name, 0), threads ].max
        end
      end

      def trim_to_budget(queues, max_threads)
        budget = max_threads.to_i
        return queues if budget <= 0

        total = queues.values.sum
        PRIORITY.reverse_each do |name|
          break if total <= budget
          next if REQUIRED.key?(name)
          next unless queues.key?(name)

          reclaimable = queues[name] - 1
          next if reclaimable <= 0

          reclaimed = [ reclaimable, total - budget ].min
          queues[name] -= reclaimed
          total -= reclaimed
        end
        queues
      end

      def serialize(queues)
        queues.map { |name, threads| "#{name}:#{threads}" }.join(";")
      end

      # Every served queue keeps one thread, so an allocation with more queues
      # than the budget cannot fit and is reported instead of hidden.
      def warn_over_budget(queues, max_threads)
        budget = max_threads.to_i
        total = queues.values.sum
        return if budget <= 0 || total <= budget

        Rails.logger.warn(
          message: "worker_settings.good_job_queues.budget_exceeded",
          queue_count: queues.size,
          queue_threads: total,
          max_threads: budget
        )
      end
    end
  end
end
