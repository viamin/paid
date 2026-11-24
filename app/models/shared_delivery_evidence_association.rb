# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-060
class SharedDeliveryEvidenceAssociation < ApplicationRecord
  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :pull_request, class_name: "Issue"
  belongs_to :authorized_by, class_name: "User"

  validates :pull_request_url, :revision, presence: true
  validate :same_tenant_and_project
  validate :merged_pull_request

  def current?
    revoked_at.nil? && pull_request.pr_review_phase == "merged" && pull_request.github_html_url == pull_request_url && pull_request.merged_commit_sha == revision
  end

  private

  def same_tenant_and_project
    errors.add(:project, "must own the source and pull request") unless [ issue, pull_request ].all? { |record| record&.project_id == project_id }
    errors.add(:account, "must own the project") unless project&.account_id == account_id
    errors.add(:authorized_by, "must belong to the account") unless authorized_by&.account_id == account_id
  end

  def merged_pull_request
    return if pull_request.blank? || (pull_request.is_pull_request? && pull_request.pr_review_phase == "merged")
    errors.add(:pull_request, "must be a merged pull request")
  end
end
