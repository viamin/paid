# frozen_string_literal: true

module HealthChecks
  # Abstract base for health checks.
  # Subclasses implement +self.scope+ and +#call+ (reads +subject+ from the instance).
  class Check
    # Stable identifier derived from the class name (e.g. :auto_merge_without_owner).
    def self.code
      name.demodulize.underscore.to_sym
    end

    # +:project+, +:user+, or +:runner+. Subclasses MUST set via +self.scope = :project+
    # or override +def self.scope+.
    class << self
      attr_writer :scope

      def scope
        @scope || raise(NotImplementedError, "#{name} must define self.scope")
      end
    end

    # Marks checks that hit external services (GitHub API, model registry).
    # Network checks are skipped when +include_network+ is false.
    def self.network?
      false
    end

    # Entry point: runs the check against +subject+ and returns an array of Findings.
    def self.call(subject)
      new(subject).call
    end

    def initialize(subject)
      @subject = subject
    end

    # Subclasses MUST implement. Returns an array of Findings (empty = pass).
    def call
      raise NotImplementedError, "#{self.class.name} must implement #call"
    end

    private

    attr_reader :subject

    # Convenience: build a single-element Finding array from the check's own metadata.
    def finding(severity:, title:, description: nil, remediation: nil, action_url: nil, subject_type: nil, subject_id: nil, metadata: {})
      [
        Finding.new(
          code: self.class.code,
          scope: self.class.scope,
          severity: severity,
          title: title,
          description: description,
          remediation: remediation,
          action_url: action_url,
          subject_type: subject_type,
          subject_id: subject_id,
          metadata: metadata
        )
      ]
    end
  end
end
