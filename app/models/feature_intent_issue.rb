# frozen_string_literal: true

# Links a feature intent to one issue in its tree (implementation issue or
# PR issue). An issue may serve several related designs; the verified receipt
# on each FeatureIntent records the distinct plan membership.
class FeatureIntentIssue < ApplicationRecord
  RELEASE_STATES = %w[held pending released reconciliation_failed].freeze

  belongs_to :feature_intent
  belongs_to :issue

  validates :issue_id, uniqueness: { scope: :feature_intent_id }
  validates :release_state, inclusion: { in: RELEASE_STATES }
end
