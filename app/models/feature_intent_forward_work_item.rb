# frozen_string_literal: true

# @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-009
class FeatureIntentForwardWorkItem < ApplicationRecord
  STATUSES = %w[pending applied].freeze

  belongs_to :feature_intent_completion
  belongs_to :affected_issue, class_name: "Issue", optional: true
  belongs_to :follow_up_issue, class_name: "Issue", optional: true

  validates :fingerprint, presence: true, length: { maximum: 64 }, uniqueness: { scope: :feature_intent_completion_id }
  validates :status, inclusion: { in: STATUSES }
end
