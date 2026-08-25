# frozen_string_literal: true

module Issues
  class IssueAnalysisBackoffResetContext
    RELEVANT_USER_SETTING_FIELDS = %w[
      issue_analysis_runner
      issue_analysis_fallback_runners
    ].freeze

    # Runner attribute changes that affect whether a specific runner is
    # enabled/authenticated for issue-analysis retries. Deliberately excludes
    # `weight`, which Runners::QuotaBalanceService rewrites on every
    # auto-weight rebalance and is unrelated to availability (see PR #3650
    # review discussion).
    RELEVANT_RUNNER_FIELDS = %w[
      discarded_at
      enabled_for_agent_runs
      auth_type
      provider_api_key_id
      integration_credential_id
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
        relevant_runner_change_at,
        owner.runner_states.maximum(:availability_changed_at),
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
      latest_relevant_version_time(owner.settings, RELEVANT_USER_SETTING_FIELDS)
    end

    # Runner rows are logidze-tracked, so (unlike RunnerState) the reset
    # signal can come from filtering log_data versions instead of a
    # dedicated column.
    def relevant_runner_change_at
      owner.runners.filter_map { |runner| latest_relevant_version_time(runner, RELEVANT_RUNNER_FIELDS) }.max
    end

    def latest_relevant_version_time(record, fields)
      return unless record&.log_data

      # Version 1 is the row's initial INSERT, not a later state change — every
      # column looks "changed" from nil at creation time, which would otherwise
      # make a brand-new record (e.g. the default runner every user gets on
      # signup) look like it just recovered.
      version = record.log_data.versions.reverse_each.find do |entry|
        entry.version > 1 && (entry.changes.keys & fields).any?
      end
      return unless version

      Time.zone.at(version.time.to_f / 1000)
    end
  end
end
