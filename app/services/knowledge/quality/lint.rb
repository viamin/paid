# frozen_string_literal: true

module Knowledge
  module Quality
    # Runs the project's knowledge through a fixed set of read-only checks
    # and returns a bounded, structured report. Each finding carries a
    # stable `code` so callers can filter and aggregate, a severity (info,
    # warning, error), and the target type/id needed to act on the issue.
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
        CHECK_CLASSES.map { |klass| klass.code }
      end

      def call
        findings = run_checks

        {
          project_id: project.id,
          generated_at: Time.current.iso8601,
          checks: CHECK_CLASSES.map { |klass| klass.code },
          findings: findings,
          summary: summarize(findings)
        }
      end

      private

      def run_checks
        findings = []
        CHECK_CLASSES.each do |klass|
          findings.concat(safe_findings(klass))
        end
        findings
      end

      def safe_findings(klass)
        klass.new(project: project).findings
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.quality.lint.check_failed",
          project_id: project.id,
          check: klass.code,
          error_class: e.class.name,
          error: e.message
        )
        []
      end

      def summarize(findings)
        buckets = SEVERITIES.index_with { 0 }.transform_keys(&:to_sym)
        findings.each do |finding|
          key = finding[:severity]&.to_sym
          buckets[key] += 1 if buckets.key?(key)
        end
        buckets.merge(total: findings.size)
      end
    end
  end
end
