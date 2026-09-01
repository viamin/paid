# frozen_string_literal: true

class KnowledgeArtifact < ApplicationRecord
  STATUSES = %w[active stale deleted].freeze

  # Curated artifact types are durable, human/agent-authored knowledge (LID
  # docs, OKF concepts, imported documents, decisions, change intents,
  # maintainer-provided business context) as opposed to artifacts a collector
  # derives from the codebase (routes, symbols, schema, and similar). This is
  # the canonical curated/derived lane distinction used across search,
  # browse, usage stats, and context-bundle assembly.
  # @spec KNOWLEDGE-CURATED-001
  CURATED_ARTIFACT_TYPES = %w[
    okf_concept business_context reference_document decision_record change_intent
  ].freeze

  belongs_to :collector_run
  belongs_to :project

  has_many :knowledge_chunks, dependent: :destroy
  has_many :active_ordered_chunks, -> { where(status: "active").order(:sequence) },
    class_name: "KnowledgeChunk", inverse_of: :knowledge_artifact

  validates :artifact_type, presence: true, length: { maximum: 100 }
  validates :collector_type, presence: true, length: { maximum: 100 }
  validates :content_hash, presence: true, length: { maximum: 64 },
    uniqueness: { scope: :collector_run_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :scope_path, length: { maximum: 1000 }, allow_nil: true
  validates :identifier, length: { maximum: 500 }, allow_nil: true
  validate :project_matches_collector_run

  scope :active, -> { where(status: "active") }
  scope :stale, -> { where(status: "stale") }
  scope :by_type, ->(type) { where(artifact_type: type) }
  scope :for_project, ->(project) { where(project: project) }
  scope :with_active_chunks, -> { joins(:active_ordered_chunks).distinct }
  scope :identifier_like, ->(query) {
    where("identifier % ?", query)
      .order(Arel.sql("similarity(identifier, #{connection.quote(query)}) DESC"), :id)
  }
  scope :curated, -> { where(artifact_type: CURATED_ARTIFACT_TYPES) }
  scope :derived, -> { where.not(artifact_type: CURATED_ARTIFACT_TYPES) }

  def self.curated_type?(artifact_type)
    CURATED_ARTIFACT_TYPES.include?(artifact_type.to_s)
  end

  def curated?
    self.class.curated_type?(artifact_type)
  end

  def self.artifact_counts_cache_key(project_id)
    "project_artifact_counts/#{project_id}"
  end

  def self.okf_export_available_cache_key(project_id)
    "project_okf_export_available/#{project_id}"
  end

  def self.bust_artifact_counts_cache(project_id)
    Rails.cache.delete(artifact_counts_cache_key(project_id))
    Rails.cache.delete(okf_export_available_cache_key(project_id))
  end

  private

  def project_matches_collector_run
    return unless collector_run&.project_version

    collector_project_id = collector_run.project_version.project_id
    if project_id.present? && collector_project_id.present? && project_id != collector_project_id
      errors.add(:project, "must match the collector run's project")
    elsif project_id.nil? && collector_project_id.present?
      self.project_id = collector_project_id
    end
  end
end
