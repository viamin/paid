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
        relevant_runner_state_change_at,
        owner.provider_api_keys.where(id: relevant_provider_api_key_ids).maximum(:updated_at),
        owner.account.integration_credentials.where(id: relevant_integration_credential_ids).maximum(:updated_at)
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

    # The runners/credentials that issue analysis can actually use. Matches
    # the union of chat_providers' two paths in
    # Activities::AnalyzeIssueActivity: the owner's configured
    # issue_analysis_runner + fallback list, and every chat-enabled Runner
    # record (the broadening fallback when no explicit selection exists).
    # Anything outside this set is irrelevant to issue analysis and must not
    # reset the cooldown — see PR #3650 review discussion.
    def relevant_runners
      owner.runners.kept_only.where(runner_key: relevant_runner_keys)
    end

    def relevant_runner_keys
      @relevant_runner_keys ||= (
        configured_issue_analysis_runner_keys + chat_capable_runner_keys
      ).uniq
    end

    def configured_issue_analysis_runner_keys
      settings = owner.settings
      return [] unless settings

      [ settings.issue_analysis_runner, *Array(settings.issue_analysis_fallback_runners) ]
        .filter_map { |value| value.to_s.strip.downcase.presence }
    end

    def chat_capable_runner_keys
      owner.runners.kept_only.for_chat.distinct.pluck(:runner_key)
    end

    def relevant_provider_api_key_ids
      relevant_runners.where.not(provider_api_key_id: nil).distinct.pluck(:provider_api_key_id)
    end

    def relevant_integration_credential_ids
      relevant_runners.where.not(integration_credential_id: nil).distinct.pluck(:integration_credential_id)
    end

    # Runner rows are logidze-tracked, so (unlike RunnerState) the reset
    # signal can come from filtering log_data versions instead of a
    # dedicated column. Scope to Runner records that back issue analysis —
    # an unrelated Runner being enabled/disabled must not reset the cooldown.
    def relevant_runner_change_at
      relevant_runners.filter_map { |runner| latest_relevant_version_time(runner, RELEVANT_RUNNER_FIELDS) }.max
    end

    # RunnerState is keyed by runner_name (a string), not Runner record id.
    # Filter to runner_names that issue analysis can actually attempt so a
    # recovery on an unrelated runner does not falsely clear the cooldown.
    def relevant_runner_state_change_at
      return if relevant_runner_keys.empty?

      owner.runner_states.where(runner_name: relevant_runner_keys).maximum(:availability_changed_at)
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
