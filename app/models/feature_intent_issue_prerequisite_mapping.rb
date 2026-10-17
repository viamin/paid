# frozen_string_literal: true

# @spec FACET-CONFIDENCE-008
class FeatureIntentIssuePrerequisiteMapping < ApplicationRecord
  include TenantScoped
  has_logidze

  COVERAGE_ASSESSMENTS = %w[unknown incomplete complete].freeze

  belongs_to :account
  belongs_to :feature_intent_issue
  has_many :prerequisites, class_name: "FeatureIntentIssuePrerequisite", dependent: :destroy

  validates :coverage_assessment, inclusion: { in: COVERAGE_ASSESSMENTS }
  validates :feature_intent_issue_id, uniqueness: true
  validate :issue_link_belongs_to_account
  validate :complete_mapping_has_material_prerequisite

  def readiness_result
    FeatureIntents::ScopedReadiness.call(project: feature_intent_issue.feature_intent.project, mapping: readiness_payload)
  end

  def readiness_payload
    {
      "coverage" => coverage_assessment,
      "scope_revision" => scope_revision,
      "prerequisites" => prerequisites.includes(:feature_intent_facet, :feature_intent_facet_direction).map(&:readiness_payload),
      "design_artifacts" => relevant_design_documents
    }
  end

  private

  def issue_link_belongs_to_account
    return if feature_intent_issue.blank? || feature_intent_issue.feature_intent.project.account_id == account_id

    errors.add(:feature_intent_issue, "must belong to the mapping account")
  end

  def complete_mapping_has_material_prerequisite
    return unless coverage_assessment == "complete" && prerequisites.empty?

    errors.add(:prerequisites, "must identify at least one material prerequisite when coverage is complete")
  end
end
