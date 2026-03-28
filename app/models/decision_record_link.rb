# frozen_string_literal: true

class DecisionRecordLink < ApplicationRecord
  LINKABLE_TYPES = %w[KnowledgeChunk Issue AgentRun DecisionRecord].freeze
  LINK_TYPES = %w[evidence implements reverts].freeze

  belongs_to :decision_record
  belongs_to :linkable, polymorphic: true, optional: true

  validates :linkable_type, presence: true, length: { maximum: 100 }, inclusion: { in: LINKABLE_TYPES }
  validates :linkable_id, presence: true, length: { maximum: 100 }
  validates :link_type, presence: true, length: { maximum: 50 }, inclusion: { in: LINK_TYPES }
end
