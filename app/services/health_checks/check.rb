# frozen_string_literal: true

module HealthChecks
  # Abstract base for health checks.
  # Subclasses implement +self.scope+ and +#call+ (reads +subject+ from the instance).
  class Check
    class << self
      attr_writer :scope

      # Stable, human-stable identifier for a finding. The dedup/auto-resolve
      # key shared with the notification pipeline (RDR-049).
      def code
        name.demodulize.underscore.to_sym
      end

      def scope
        @scope || raise(NotImplementedError, "#{name} must define self.scope")
      end

      def call(subject)
        new(subject).call
      end
    end

    # Marks checks that hit external services (GitHub API, model registry).
    # Network checks are skipped when +include_network+ is false.
    def self.network?
      false
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

    def finding(severity:, title:, description: nil, remediation: nil, action_url: nil,
      subject_type: nil, subject_id: nil, metadata: {})
      [
        Finding.new(
          code: self.class.code,
          scope: self.class.scope,
          severity: severity,
          title: title,
          description: description,
          remediation: remediation,
          action_url: action_url,
          subject_type: subject_type || subject.class.name,
          subject_id: subject_id || subject.try(:id),
          metadata: metadata
        )
      ]
    end

    # Deep-link to the settings surface where this finding can be fixed.
    # Returns nil for unpersisted subjects (e.g. in unit tests) so the UI
    # simply omits the link rather than rendering a broken path.
    def settings_action_url(path_helper, anchor: nil)
      return nil unless subject.respond_to?(:persisted?) && subject.persisted?

      path = Rails.application.routes.url_helpers.public_send(path_helper, subject)
      anchor ? "#{path}##{anchor}" : path
    end

    # Like #settings_action_url but for collection/singleton routes (e.g. the
    # runners index) whose helper does not take the subject as an argument.
    def collection_action_url(path_helper, anchor: nil)
      return nil unless subject.respond_to?(:persisted?) && subject.persisted?

      path = Rails.application.routes.url_helpers.public_send(path_helper)
      anchor ? "#{path}##{anchor}" : path
    end
  end
end
