# frozen_string_literal: true

class ProviderApiKey < ApplicationRecord
  COMPATIBILITY_LABELS = {
    "openrouter" => "OpenRouter"
  }.freeze

  belongs_to :user
  has_many :providers, dependent: :restrict_with_error

  encrypts :api_key

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { scope: :user_id }
  validates :api_key, presence: true
  validates :compatible_providers, presence: true

  validate :compatible_providers_must_be_valid

  scope :ordered, -> { order(:name) }
  scope :compatible_with, ->(provider_key) {
    where("compatible_providers @> ?", [ provider_key ].to_json)
  }

  def compatible_with?(provider_key)
    compatible_providers.include?(provider_key.to_s)
  end

  def self.compatibility_target_labels
    provider_labels = Provider.addable_provider_keys
      .flat_map { |provider_key| Provider.required_api_key_targets_for(provider_key: provider_key) }
      .uniq
      .index_with { |key| COMPATIBILITY_LABELS[key] || Provider.display_name(key) }

    provider_labels.merge(COMPATIBILITY_LABELS)
  end

  def masked_api_key
    raw = api_key.to_s
    if raw.length > 12
      "#{raw[0..7]}****#{raw[-4..]}"
    else
      "****"
    end
  end

  def display_compatible_providers
    labels = self.class.compatibility_target_labels
    compatible_providers.map { |key| labels[key] || key.to_s.titleize }.join(", ")
  end

  private

  def compatible_providers_must_be_valid
    return if compatible_providers.blank?

    unless compatible_providers.is_a?(Array)
      errors.add(:compatible_providers, "must be an array")
      return
    end

    allowed = self.class.compatibility_target_labels.keys
    invalid = compatible_providers - allowed
    return if invalid.empty?

    errors.add(:compatible_providers, "contains unsupported providers: #{invalid.join(', ')}")
  end
end
