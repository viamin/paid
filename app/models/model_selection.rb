# frozen_string_literal: true

class ModelSelection < ApplicationRecord
  SELECTOR_TYPES = %w[meta_agent rules override manual].freeze

  belongs_to :agent_run
  belongs_to :llm_model

  validates :selector_type, presence: true, inclusion: { in: SELECTOR_TYPES }
  validates :agent_run_id, uniqueness: true
  validates :complexity_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
end
