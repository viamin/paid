# frozen_string_literal: true

class ConfigurationBundle < ApplicationRecord
  belongs_to :account, optional: true

  has_many :bundle_outcomes, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validate :json_columns_are_objects

  scope :active, -> { where(is_active: true) }
  scope :baseline, -> { where(is_baseline: true) }

  def to_execution_config
    {
      prompts: prompt_versions,
      models: model_preferences,
      orchestration: orchestration_config,
      thresholds: thresholds
    }
  end

  private

  def json_columns_are_objects
    %i[prompt_versions model_preferences orchestration_config thresholds context_selector].each do |column|
      next if public_send(column).is_a?(Hash)

      errors.add(column, "must be a JSON object")
    end
  end
end
