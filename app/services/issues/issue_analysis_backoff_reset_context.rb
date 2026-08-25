# frozen_string_literal: true

module Issues
  class IssueAnalysisBackoffResetContext
    RELEVANT_USER_SETTING_FIELDS = %w[
      issue_analysis_runner
      issue_analysis_fallback_runners
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      return unless owner

      [
        issue_analysis_settings_updated_at,
        owner.runners.maximum(:updated_at),
        owner.runner_states.maximum(:updated_at),
        owner.provider_api_keys.maximum(:updated_at),
        owner.account.integration_credentials.maximum(:updated_at)
      ].compact.max
    end

    private

    attr_reader :project

    def owner
      project.effective_owner
    end

    def issue_analysis_settings_updated_at
      settings = owner.settings
      return unless settings&.log_data

      version = settings.log_data.versions.reverse_each.find do |entry|
        relevant_setting_change?(entry)
      end
      return unless version

      Time.zone.at(version.time.to_f / 1000)
    end

    def relevant_setting_change?(version)
      (version.changes.keys & RELEVANT_USER_SETTING_FIELDS).any?
    end
  end
end
