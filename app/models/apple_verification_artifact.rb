# frozen_string_literal: true

# @spec APPLE-VERIFY-004
class AppleVerificationArtifact < ApplicationRecord
  CAPTURE_KINDS = %w[screenshot recording].freeze
  RESULT_KIND = "result"
  RESULT_LABELS = {
    "build" => "Build result",
    "test" => "Test result",
    "coverage" => "Coverage",
    "policy" => "Policy decision"
  }.freeze

  belongs_to :apple_verification_attempt
  validates :kind, :storage_key, presence: true

  def protected_capture? = kind.in?(CAPTURE_KINDS)

  def result? = kind == RESULT_KIND

  def result_details
    metadata.fetch("results", {}).filter_map do |name, details|
      next unless details.is_a?(Hash)

      [ name, details.slice("outcome", "source") ]
    end.to_h
  end

  def result_label_for(name) = RESULT_LABELS.fetch(name, name.humanize)
end
