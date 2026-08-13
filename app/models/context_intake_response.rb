# frozen_string_literal: true

class ContextIntakeResponse < ApplicationRecord
  PROVENANCES = %w[human agent].freeze

  belongs_to :context_intake_session
  belongs_to :parent_response, class_name: "ContextIntakeResponse", optional: true

  has_many :follow_up_responses, class_name: "ContextIntakeResponse",
    foreign_key: :parent_response_id, dependent: :nullify, inverse_of: :parent_response

  validates :question_key, presence: true, length: { maximum: 200 }
  validates :question_text, presence: true
  validates :section, presence: true, length: { maximum: 100 }
  validates :provenance, inclusion: { in: PROVENANCES }, allow_nil: true

  scope :for_section, ->(section) { where(section: section) }
  scope :answered, -> { where.not(answer_text: [ nil, "" ]).or(where(skipped: true)) }
  scope :unanswered, -> { where(answer_text: [ nil, "" ]).where(skipped: false) }
  scope :predefined, -> { where(is_follow_up: false) }
  scope :follow_ups, -> { where(is_follow_up: true) }
  scope :ordered, -> { order(:section, :sequence) }

  def answered?
    answer_text.present? || skipped?
  end

  def human_provided?
    provenance == "human"
  end

  def agent_generated?
    provenance == "agent"
  end
end
