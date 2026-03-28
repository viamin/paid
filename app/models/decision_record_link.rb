# frozen_string_literal: true

class DecisionRecordLink < ApplicationRecord
  LINKABLE_TYPES = %w[KnowledgeChunk Issue AgentRun DecisionRecord].freeze
  LINK_TYPES = %w[evidence implements reverts].freeze

  belongs_to :decision_record
  # linkable_type/linkable_id are NOT NULL at the DB level, but we use optional: true
  # because the linkable_id is stored as a string (not a DB foreign key), so Rails
  # can't validate existence across polymorphic types. Presence is enforced by the
  # validates calls below.
  belongs_to :linkable, polymorphic: true, optional: true

  validates :linkable_type, presence: true, length: { maximum: 100 }, inclusion: { in: LINKABLE_TYPES }
  validates :linkable_id, presence: true, length: { maximum: 100 }
  validates :link_type, presence: true, length: { maximum: 50 }, inclusion: { in: LINK_TYPES }
end
