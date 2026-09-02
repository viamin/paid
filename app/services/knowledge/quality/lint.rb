# frozen_string_literal: true

module Knowledge
  module Quality
    # Runs the project's knowledge through a fixed set of read-only checks
    # and returns a bounded, structured report. Each finding carries a
    # stable `code` so callers can filter and aggregate, a severity (info,
    # warning, error), and the target type/id needed to act on the issue.
    # Each check contributes at most MAX_FINDINGS_PER_CHECK findings; checks
    # that exceed it are listed in `truncated_checks` with an omitted count.
    #
    # The report is read-only: no knowledge state is mutated. Existing
    # collection, search, context-bundle, and redaction behavior is
    # unchanged.
    #
    # @example
    #   Knowledge::Quality::Lint.call(project: project)
    class Lint
      # @spec KNOWLEDGE-LINT-001
      SEVERITIES = %w[info warning error].freeze
      MAX_FINDINGS_PER_CHECK = 500
      CHECK_CLASSES = [
        Knowledge::Quality::Checks::StaleScopePath,
        Knowledge::Quality::Checks::StaleCommitReference,
        Knowledge::Quality::Checks::OrphanedArtifact,
        Knowledge::Quality::Checks::OrphanedChunk,
        Knowledge::Quality::Checks::DanglingLink,
        Knowledge::Quality::Checks::EmptyArtifact,
        Knowledge::Quality::Checks::FullyRedactedArtifact,
        Knowledge::Quality::Checks::ChunkMissingEmbedding,
        Knowledge::Quality::Checks::ChunkMissingRedactionScan,
        Knowledge::Quality::Checks::LowUsageType,
        Knowledge::Quality::Checks::NeverRunCollector,
        Knowledge::Quality::Checks::FailedCollector,
        Knowledge::Quality::Checks::StaleCollector
      ].freeze

      attr_reader :project

      def initialize(project:)
        @project = project
      end

      def self.call(...)
        new(...).call
      end

      def self.check_codes
        CHECK_CLASSES.map(&:code)
      end

      # Aggregate findings into a severity histogram plus total. Exposed so
      # callers that filter the findings array (e.g. the API endpoint's
      # `min_severity` param) can recompute the summary to match the
      # filtered view instead of the raw report.
      def self.summarize(findings)
        buckets = SEVERITIES.index_with { 0 }.transform_keys(&:to_sym)
        findings.each do |finding|
          key = finding[:severity]&.to_sym
          buckets[key] += 1 if buckets.key?(key)
        end
        buckets.merge(total: findings.size)
      end

      def call
        findings, truncated_checks = run_checks

        {
          project_id: project.id,
          generated_at: Time.current.iso8601,
          checks: CHECK_CLASSES.map(&:code),
          findings: findings,
          truncated_checks: truncated_checks,
          summary: self.class.summarize(findings)
        }
      end

      private

      # Caps each check's contribution to MAX_FINDINGS_PER_CHECK so a single
      # check with e.g. tens of thousands of matches can't blow up the JSON
      # payload or the findings list view. Checks that hit the cap are
      # reported in `truncated_checks` with how many findings were omitted.
      def run_checks
        findings = []
        truncated_checks = []

        CHECK_CLASSES.each do |klass|
          result = safe_finding_report(klass)
          findings.concat(result.findings)
          truncated_checks << { code: klass.code, omitted_count: result.omitted_count } if result.omitted_count.positive?
        end

        [ findings, truncated_checks ]
      end

      def safe_finding_report(klass)
        klass.new(project: project).finding_report(max: MAX_FINDINGS_PER_CHECK)
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.quality.lint.check_failed",
          project_id: project.id,
          check: klass.code,
          error_class: e.class.name,
          error: e.message
        )
        Checks::Base::Result.new(findings: [], omitted_count: 0)
      end
    end
  end
end
