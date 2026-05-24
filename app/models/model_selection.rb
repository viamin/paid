# frozen_string_literal: true

class ModelSelection < ApplicationRecord
  SELECTOR_TYPES = %w[meta_agent rules override manual quality_escalation].freeze

  belongs_to :agent_run
  belongs_to :llm_model, optional: true

  validates :selector_type, presence: true, inclusion: { in: SELECTOR_TYPES }
  validates :agent_run_id, uniqueness: true
  validates :complexity_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :tier, presence: true, inclusion: { in: LlmModel::TIERS }
  validates :escalated_from_tier, inclusion: { in: LlmModel::TIERS }, allow_nil: true

  scope :escalated, -> { where.not(escalated_from_tier: nil) }

  def escalated?
    escalated_from_tier.present?
  end
end
