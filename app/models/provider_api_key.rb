# frozen_string_literal: true

class ProviderApiKey < ApplicationRecord
  belongs_to :user
  has_many :providers, dependent: :restrict_with_error

  encrypts :api_key_ciphertext

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { scope: :user_id }
  validates :api_key_ciphertext, presence: true
  validates :compatible_providers, presence: true

  validate :compatible_providers_must_be_valid

  scope :ordered, -> { order(:name) }
  scope :compatible_with, ->(provider_key) {
    where("compatible_providers @> ?", [ provider_key ].to_json)
  }

  def compatible_with?(provider_key)
    compatible_providers.include?(provider_key.to_s)
  end

  def display_compatible_providers
    compatible_providers.map(&:titleize).join(", ")
  end

  private

  def compatible_providers_must_be_valid
    return if compatible_providers.blank?

    unless compatible_providers.is_a?(Array)
      errors.add(:compatible_providers, "must be an array")
      return
    end

    supported = ProviderSupport.supported_provider_keys
    invalid = compatible_providers - supported
    return if invalid.empty?

    errors.add(:compatible_providers, "contains unsupported providers: #{invalid.join(', ')}")
  end
end
