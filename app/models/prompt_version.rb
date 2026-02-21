# frozen_string_literal: true

class PromptVersion < ApplicationRecord
  belongs_to :prompt
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_version, class_name: "PromptVersion", optional: true

  has_many :agent_runs, dependent: :nullify

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :prompt_id }
  validates :template, presence: true

  validate :immutable_after_creation, on: :update

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

  def immutable_after_creation
    errors.add(:base, "prompt versions are immutable after creation")
  end
end
