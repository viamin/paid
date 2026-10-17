# frozen_string_literal: true

# @spec FACET-CONFIDENCE-001
class FeatureIntentFacetDirection < ApplicationRecord
  include TenantScoped
  has_logidze

  STATUSES = %w[active superseded].freeze

  belongs_to :account
  belongs_to :feature_intent_facet
  has_many :evidence, class_name: "FeatureIntentFacetEvidence", dependent: :nullify
  has_many :assessments, class_name: "FeatureIntentFacetAssessment", dependent: :restrict_with_error

  validates :name, :description, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :name, uniqueness: { scope: :feature_intent_facet_id }
  validate :facet_belongs_to_account

  private

  def facet_belongs_to_account
    return if feature_intent_facet.blank? || feature_intent_facet.account_id == account_id

    errors.add(:feature_intent_facet, "must belong to the direction account")
  end
end
