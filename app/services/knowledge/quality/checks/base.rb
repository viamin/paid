# frozen_string_literal: true

module Knowledge
  module Quality
    # Base class for read-only knowledge lint/drift checks. Each check
    # advertises a stable `code` (used by callers to filter/aggregate findings)
    # and a default `severity`; subclasses produce findings via #findings.
    #
    # Checks MUST NOT mutate knowledge state — the lint report is a passive
    # reporting surface, not a fix-forward tool.
    class Checks::Base
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
      def findings
        raise NotImplementedError
      end

      protected

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
    end
  end
end
