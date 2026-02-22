# frozen_string_literal: true

class PromptVersion < ApplicationRecord
  IMMUTABLE_ATTRIBUTES = %w[template version prompt_id created_by_user_id parent_version_id variables system_prompt created_by change_notes].freeze

  belongs_to :prompt
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_version, class_name: "PromptVersion", optional: true

  has_many :agent_runs, dependent: :nullify

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :prompt_id }
  validates :template, presence: true

  validate :immutable_content_after_creation, on: :update

  # Renders the template by interpolating variables.
  #
  # @param vars [Hash] Variable name-value pairs to interpolate
  # @return [String] The rendered template
  def render(vars = {})
    result = template.dup
    vars.each do |key, value|
      result.gsub!("{{#{key}}}", value.to_s)
    end
    result
  end

  private

  def immutable_content_after_creation
    if (changes.keys & IMMUTABLE_ATTRIBUTES).any?
      errors.add(:base, "prompt version content fields are immutable after creation")
    end
  end
end
