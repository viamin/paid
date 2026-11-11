# frozen_string_literal: true

module WorkItems
  # Imports an account's Linear tickets through an enabled project. Every
  # provider identity is upserted once, regardless of how many projects sync.
  class SyncLinear
    def self.call(...) = new(...).call

    def initialize(project:)
      @project = project
    end

    # @spec UNIFIED-WORK-ITEMS-003 UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-006 UNIFIED-WORK-ITEMS-009
    def call
      return 0 unless Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project)
      return 0 unless configuration&.enabled? && configuration.tracker_type == "linear"

      issues = configuration.adapter.list_issues
      synced_at = Time.current
      WorkItem.transaction do
        issues.each { |issue| upsert(issue, synced_at:) }
        configuration.update!(last_synced_at: synced_at, last_sync_error: nil, connection_health: "healthy")
      end
      issues.length
    rescue IssueTrackers::Adapters::Linear::RateLimitedError
      mark_failure("rate_limited")
      raise
    rescue IssueTrackers::Adapters::Linear::AuthenticationError
      mark_failure("auth_failed")
      raise
    rescue IssueTrackers::Adapters::Linear::ResponseError
      mark_failure("error")
      raise
    end

    private

    attr_reader :project

    def configuration
      @configuration ||= project.account.tracker_configuration
    end

    def upsert(issue, synced_at:)
      payload = issue.metadata.fetch("raw_payload")
      item = WorkItem.find_or_initialize_by(account: project.account, provider: "linear",
        resource_type: "issue", external_id: issue.external_id)
        previous_native_project_id = item.native_project_id
      item.assign_attributes(tracker_configuration: configuration, title: issue.title,
        body: issue.body, priority: payload["priority"], url: issue.url,
        raw_payload: payload, provider_created_at: parse_time(payload["createdAt"]),
        provider_updated_at: parse_time(payload["updatedAt"]),
        archived_at: parse_time(payload["archivedAt"]), last_synced_at: synced_at,
        native_project_id: payload.dig("project", "id"), native_project_name: payload.dig("project", "name"))
      item.save!
        WorkItems::ProjectMappings::AutoAssign.call(work_item: item, previous_native_project_id:)
      WorkItems::Lifecycle::ApplyProviderChange.call(work_item: item, native_state: issue.status, project:)
    end

    def parse_time(value)
      Time.iso8601(value) if value.present?
    end

    def mark_failure(state)
      configuration&.update!(connection_health: state, last_sync_error: state)
    end
  end
end
