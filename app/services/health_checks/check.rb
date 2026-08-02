# frozen_string_literal: true

module HealthChecks
  class Check
    class << self
      attr_reader :scope
      attr_writer :scope

      # Stable, human-stable identifier for a finding. The dedup/auto-resolve
      # key shared with the notification pipeline (RDR-049).
      def code = name.demodulize.underscore.to_sym

      def call(subject)
        new(subject).call
      end

      def network?
        true
      end
    end

    def initialize(subject)
      @subject = subject
    end

    private

    attr_reader :subject

    def finding(severity:, title:, description:, remediation:, action_url: nil, metadata: {})
      [
        Finding.new(
          code: self.class.code,
          scope: self.class.scope,
          severity: severity,
          title: title,
          description: description,
          remediation: remediation,
          action_url: action_url,
          subject_type: subject.class.name,
          subject_id: subject.id,
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
