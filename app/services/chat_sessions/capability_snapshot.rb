# frozen_string_literal: true

module ChatSessions
  class CapabilitySnapshot
    LABELS = {
      "none" => "No workspace",
      "pending" => "Workspace pending",
      "provisioning" => "Workspace preparing",
      "ready" => "Workspace ready",
      "failed" => "Workspace failed",
      "stopped" => "Workspace stopped"
    }.freeze

    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      {
        type: "capability_changed",
        container_capability: chat_session.container_capability,
        container_capability_label: LABELS.fetch(chat_session.container_capability, LABELS.fetch("none")),
        container_ready_at: chat_session.container_ready_at,
        cloned_repos: cloned_repos
      }
    end

    private

    def cloned_repos
      projects_by_id = TenantContext.with_system_access { Project.where(id: manifest_project_ids).index_by(&:id) }

      chat_session.clone_manifest_entries.map do |entry|
        project = projects_by_id[entry[:project_id].to_i]

        {
          project_id: entry[:project_id].to_i,
          project_name: entry[:project_name].presence || project&.name || "Project ##{entry[:project_id]}",
          project_full_name: entry[:project_full_name].presence || project&.full_name,
          path: entry[:path],
          token_identity: entry[:token_identity],
          stale: entry[:stale] == true,
          stale_reason: entry[:stale_reason].presence,
          stale_at: entry[:stale_at].presence,
          status: entry[:status].presence
        }.compact
      end
    end

    def manifest_project_ids
      chat_session.clone_manifest_entries.map { |entry| entry[:project_id].to_i }.uniq
    end
  end
end
