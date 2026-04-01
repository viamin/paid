# frozen_string_literal: true

class ProviderApiKey < ApplicationRecord
  belongs_to :user
  has_many :providers, dependent: :restrict_with_error

  encrypts :api_key

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { scope: :user_id }
  validates :api_key, presence: true
  validates :api_service_type, presence: true, length: { maximum: 50 }

  validate :api_service_type_must_be_valid

  scope :ordered, -> { order(:name) }
  scope :for_api_service_type, ->(service_type) {
    where(api_service_type: service_type)
  }

  def compatible_with?(provider_key)
    api_service_type == ProviderSupport.api_service_type_for(provider_key)
  end

  def self.api_service_type_options
    ProviderSupport.api_service_types.map { |key, label| [ label, key ] }
  end

  def display_api_service_type
    ProviderSupport.api_service_type_label(api_service_type)
  end

  def masked_api_key
    raw = api_key.to_s
    if raw.length > 12
      "#{raw[0..7]}****#{raw[-4..]}"
    else
      "****"
    end
  end

  private

  def api_service_type_must_be_valid
    return if api_service_type.blank?

    normalized = api_service_type.to_s.strip.downcase
    self.api_service_type = normalized

    return if ProviderSupport.api_service_types.key?(normalized)

    errors.add(:api_service_type, "is not a supported API service type")
  end
end
