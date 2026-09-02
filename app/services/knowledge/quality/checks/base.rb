# frozen_string_literal: true

module Knowledge
  module Quality
    # Base class for read-only knowledge lint/drift checks. Each check
    # advertises a stable `code` (used by callers to filter/aggregate findings)
    # and a default `severity`; subclasses stream findings via
    # `#collect_findings`.
    #
    # Checks MUST NOT mutate knowledge state — the lint report is a passive
    # reporting surface, not a fix-forward tool.
    class Checks::Base
      Result = Struct.new(:findings, :omitted_count, keyword_init: true)
      SEVERITIES = %w[info warning error].freeze

      class << self
        def code(value = nil)
          @code ||= value
        end

        def severity(value = nil)
          @severity ||= value
        end
      end

      attr_reader :project

      def initialize(project:)
        @project = project
      end

      def code = self.class.code
      def severity = self.class.severity

      # @return [Array<Hash>] Findings with keys :code, :severity,
      #   :target_type, :target_id, :artifact_type (optional), :detail.
      def findings(max: nil)
        finding_report(max: max).findings
      end

      def finding_report(max: nil)
        collector = FindingCollector.new(max: max)
        collect_findings(collector)
        collector.result
      end

      protected

      def collect_findings(_collector)
        raise NotImplementedError
      end

      def add_finding(collector, **attributes)
        collector.add { build_finding(**attributes) }
      end

      def build_finding(target_type:, target_id:, detail:, severity: nil, artifact_type: nil, extra: {})
        {
          code: code,
          severity: severity || self.severity,
          target_type: target_type,
          target_id: target_id.to_s,
          artifact_type: artifact_type,
          detail: detail,
          **extra
        }
      end

      # Count-then-load pattern for scopes where every matching row (or
      # group, for `GROUP BY ... HAVING` scopes) becomes exactly one
      # finding. Runs a cheap aggregate first, then instantiates AR objects
      # for only `remaining_capacity` rows and reports the rest as omitted.
      # This keeps the work bounded, not just the payload — the whole point
      # of the per-check cap in KNOWLEDGE-LINT-001.
      #
      # `grouped:` — when true, the scope has `GROUP BY`/`HAVING` and
      # `.count` returns a Hash; we take its `.size` to get the number of
      # distinct groups.
      # `batch_size:` — passed to `find_each` for the load phase.
      # The block receives each loaded record and returns the finding hash
      # to store (usually via `build_finding(...)`).
      def collect_scope(collector, scope, grouped: false, batch_size: 200)
        total = grouped ? scope.count.size : scope.count
        return if total.zero?

        capacity = collector.remaining_capacity
        loaded = 0
        if capacity.positive?
          limit = capacity == Float::INFINITY ? total : capacity
          scope.limit(limit).find_each(batch_size: batch_size) do |record|
            collector.add { yield(record) }
            loaded += 1
          end
        end
        collector.bump_count(total - loaded)
      end

      class FindingCollector
        def initialize(max:)
          @max = max
          @findings = []
          @count = 0
        end

        def add
          @count += 1
          return if @max && @findings.size >= @max

          @findings << yield
        end

        # Contribute `n` items to the seen-count without individually adding
        # them via `add`. Used by count-then-load checks that computed the
        # total from a cheap aggregate and loaded only up to
        # `remaining_capacity` rows.
        def bump_count(n)
          @count += n
        end

        # How many more findings this collector will store before spilling
        # into the omitted bucket. Returns `Float::INFINITY` when no cap
        # was configured.
        def remaining_capacity
          return Float::INFINITY unless @max

          [ @max - @findings.size, 0 ].max
        end

        def result
          Result.new(findings: @findings, omitted_count: @count - @findings.size)
        end
      end
    end
  end
end
