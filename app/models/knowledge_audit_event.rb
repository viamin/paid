# frozen_string_literal: true

class KnowledgeAuditEvent < ApplicationRecord
  # Currently instrumented event types. Additional types (e.g. chunk_redacted,
  # decision_drafted) will be added as their corresponding mutations are
  # implemented in future issues.
  EVENT_TYPES = %w[
    artifact_created artifact_staled chunk_embedded
    collection_rebuilt
  ].freeze

  # Provenance chain: audit event → target (artifact/chunk) → collector_run → project.
  # The actor field captures who performed the action (e.g. actor_type: "collector",
  # actor_id: collector_run.id). Full provenance (collector_run_id, commit_sha,
  # tool_version) is reachable by joining target → collector_run → project_version.
  # The `details` JSONB column carries event-specific context:
  #   artifact_created:    { artifact_type:, identifier: }
  #   artifact_staled:     { identifier: }
  #   chunk_embedded:      { model:, dimensions: }
  #   collection_rebuilt:  { collection_name: }
  belongs_to :project

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :actor_type, length: { maximum: 50 }, allow_nil: true
  validates :actor_id, length: { maximum: 100 }, allow_nil: true
  validates :target_type, length: { maximum: 100 }, allow_nil: true
  validates :target_id, length: { maximum: 100 }, allow_nil: true

  scope :for_project, ->(project) { where(project: project) }
  scope :by_event_type, ->(type) { where(event_type: type) }
  scope :by_target, ->(type, id) { where(target_type: type, target_id: id) }
  scope :since, ->(time) { where("created_at >= ?", time) }
  scope :before, ->(time) { where("created_at <= ?", time) }
  scope :ordered, -> { order(created_at: :desc, id: :desc) }
end
