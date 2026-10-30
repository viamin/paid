# frozen_string_literal: true

require "digest"

# Binds one completed audit's evidence basis to a reproducible package
# identity. A later change to any bound input creates a new package revision
# and retains the prior record; approval records the business reviewer's
# validation of that revision without authorizing repair or release.
# @spec LAYERED-VERIFY-023
class LayeredVerificationReviewPackage < ApplicationRecord
  belongs_to :project
  belongs_to :agent_run

  validates :package_digest, :revision, presence: true
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :package_digest, uniqueness: { scope: :project_id }

  def self.bind!(agent_run:)
    inputs = bound_inputs(agent_run)
    digest = digest_for(inputs)
    existing = agent_run.project.layered_verification_review_packages.find_by(package_digest: digest)
    return existing if existing

    create_package!(agent_run:, inputs:, digest:)
  end

  def approve!(user:)
    with_lock do
      update!(approvals: approvals + [ {
        "user_id" => user.id,
        "approved_at" => Time.current.iso8601,
        "package_revision" => revision,
        "package_digest" => package_digest
      } ])
    end
  end

  class << self
    private

    def bound_inputs(agent_run)
      metadata = agent_run.external_metadata.fetch("layered_verification", {})
      obligations = agent_run.project.layered_verification_obligations
        .where(id: Array(metadata["obligation_ids"])).order(:id)
      {
        "obligations" => obligations.map do |obligation|
          { "id" => obligation.id, "external_identity" => obligation.external_identity,
            "external_revision" => obligation.external_revision, "approval_state" => obligation.approval_state }
        end,
        "scope" => { "obligation_ids" => obligations.ids, "target_revision" => metadata["target_revision"] },
        "plan_revision" => Digest::SHA256.hexdigest(metadata.fetch("plan", {}).to_json),
        "check_result_ids" => LayeredVerificationCheckResult.where(agent_run:, obligation: obligations).order(:id).ids,
        "inbox_decisions" => inbox_decisions(agent_run.project, obligations)
      }
    end

    def digest_for(inputs)
      Digest::SHA256.hexdigest(inputs.to_json)
    end

    def inbox_decisions(project, obligations)
      LayeredVerificationFinding.where(project:, obligation: obligations)
        .where("decision ? :key", key: "selected_action").order(:id)
        .map { |finding| finding.decision.merge("finding_id" => finding.id) }
    end

    def create_package!(agent_run:, inputs:, digest:)
      prior = where(agent_run:).order(:revision).last
      create!(
        project: agent_run.project, agent_run:,
        revision: (prior&.revision || 0) + 1,
        package_digest: digest, bound_inputs: inputs.except("inbox_decisions"),
        approvals: prior&.approvals || [], inbox_decisions: inputs.fetch("inbox_decisions", [])
      )
    end
  end
end
