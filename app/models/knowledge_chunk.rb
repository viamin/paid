# frozen_string_literal: true

class KnowledgeChunk < ApplicationRecord
  STATUSES = %w[active stale deleted redacted].freeze
  CHUNK_TYPES = %w[definition summary context evidence].freeze

  belongs_to :knowledge_artifact
  belongs_to :project

  has_many :outgoing_links, class_name: "KnowledgeLink", foreign_key: :source_chunk_id,
    dependent: :destroy, inverse_of: :source_chunk
  has_many :incoming_links, class_name: "KnowledgeLink", foreign_key: :target_chunk_id,
    dependent: :destroy, inverse_of: :target_chunk

  validates :chunk_type, presence: true, inclusion: { in: CHUNK_TYPES }
  validates :content, presence: true
  validates :content_hash, presence: true, length: { maximum: 64 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :project_matches_knowledge_artifact_project

  scope :active, -> { where(status: "active") }
  scope :embeddable, -> { active.where.not(embedding_model: nil) }
  scope :needs_embedding, -> { active.where(embedding_model: nil) }
  scope :by_project, ->(project_id) { where(project_id: project_id) }
  scope :for_project, ->(project) { where(project: project) }
  scope :ordered, -> { order(:sequence) }
  scope :full_text_search, ->(query) {
    rank_expr = "ts_rank(content_tsvector, plainto_tsquery('pg_catalog.english', #{connection.quote(query)}))"
    where("content_tsvector @@ plainto_tsquery('pg_catalog.english', ?)", query)
      .select("#{table_name}.*, #{rank_expr} AS relevance_rank")
      .order(Arel.sql("#{rank_expr} DESC, #{table_name}.id ASC"))
  }

  before_save :update_content_tsvector, if: :should_update_content_tsvector?

  def self.content_tsvector_trigger_present?
    return @content_tsvector_trigger_present if defined?(@content_tsvector_trigger_present)

    sql = <<~SQL.squish
      SELECT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT t.tgisinternal
          AND n.nspname = ANY (current_schemas(false))
          AND c.relname = #{connection.quote(table_name)}
          AND t.tgfoid::regproc::text = 'tsvector_update_trigger'
      )
    SQL

    @content_tsvector_trigger_present = connection.select_value(sql)
  end

  def self.reset_content_tsvector_trigger_cache!
    remove_instance_variable(:@content_tsvector_trigger_present) if defined?(@content_tsvector_trigger_present)
  end

  private

  def should_update_content_tsvector?
    will_save_change_to_content? && !self.class.content_tsvector_trigger_present?
  end

  def update_content_tsvector
    self.content_tsvector = self.class.connection.select_value(
      Arel.sql("SELECT to_tsvector('pg_catalog.english', #{self.class.connection.quote(content)})")
    )
  end

  def project_matches_knowledge_artifact_project
    return if knowledge_artifact.nil? || project_id.nil?
    return if knowledge_artifact.project_id == project_id

    errors.add(:project, "must match knowledge artifact's project")
  end
end
