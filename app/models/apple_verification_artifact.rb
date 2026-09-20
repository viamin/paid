# frozen_string_literal: true

# @spec APPLE-VERIFY-004
class AppleVerificationArtifact < ApplicationRecord
  CAPTURE_KINDS = %w[screenshot recording].freeze
  belongs_to :apple_verification_attempt
  validates :kind, :storage_key, presence: true

  def protected_capture? = kind.in?(CAPTURE_KINDS)
end
