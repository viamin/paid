# frozen_string_literal: true

require "set"

class ProviderApiKey < ApplicationRecord
  has_logidze
  belongs_to :user
  has_many :runners, -> { kept }, dependent: :restrict_with_error
  has_many :providers, -> { kept }, class_name: "Provider", dependent: :restrict_with_error

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

  # Returns true when this API key's service type is compatible with the
  # given provider. Providers with a fixed service type (claude → anthropic)
  # are checked against ProviderSupport::PROVIDER_API_SERVICE_TYPE. Providers
  # that support multiple upstream API providers (opencode, kilocode, aider, pi)
  # resolve compatibility from their provider-specific service-type sets.
  DYNAMIC_API_PROVIDER_KEYS = %w[opencode kilocode aider pi].to_set.freeze

  def compatible_with?(provider_key)
    if DYNAMIC_API_PROVIDER_KEYS.include?(provider_key.to_s)
      compatible_dynamic_service_type?(provider_key)
    else
      static_type = ProviderSupport.api_service_type_for(provider_key)
      return api_service_type == static_type if static_type

      static_type = RunnerSupport.api_service_type_for(provider_key)
      static_type.present? && api_service_type == static_type
    end
  end

  def self.api_service_type_options
    RunnerSupport.api_service_types.map { |key, label| [ label, key ] }
  end

  def display_api_service_type
    RunnerSupport.api_service_type_label(api_service_type)
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

  def compatible_dynamic_service_type?(provider_key)
    case provider_key.to_s
    when "pi"
      Provider::PI_API_PROVIDERS.values.any? { |config| config[:service_type] == api_service_type }
    else
      Provider::DIRECT_OUTBOUND_SERVICE_TYPES.include?(api_service_type)
    end
  end

  def api_service_type_must_be_valid
    return if api_service_type.blank?

    normalized = api_service_type.to_s.strip.downcase
    self.api_service_type = normalized

    return if RunnerSupport.api_service_types.key?(normalized)

    errors.add(:api_service_type, "is not a supported API service type")
  end
end
