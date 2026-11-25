# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-063
class SharedDeliveryEvidenceAssociation < ApplicationRecord
  def self.canonical_url_for(pull_request)
    repository = if pull_request.source == Issue::UPSTREAM_PULL_REQUEST_SOURCE
      pull_request.project.upstream_full_name
    else
      pull_request.project.full_name
    end
    "https://github.com/#{repository}/pull/#{pull_request.github_number}"
  end

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :pull_request, class_name: "Issue"
  belongs_to :authorized_by, class_name: "User", optional: true

  validates :pull_request_url, :revision, presence: true
  validates :revision, format: { with: /\A[0-9a-f]{40}\z/i }
  validate :same_tenant_and_project
  validate :merged_pull_request
  validate :canonical_pull_request_identity

  def current?
    [ issue, pull_request ].all? { |record| record.project_id == project_id } &&
      project.account_id == account_id && authorized_by&.account_id == account_id &&
      revoked_at.nil? && pull_request.github_state == "closed" && pull_request.pr_review_phase == "merged" &&
      pull_request.github_html_url == canonical_pull_request_url &&
      canonical_pull_request_url == pull_request_url && pull_request.merged_commit_sha == revision
  end

  private

  def same_tenant_and_project
    errors.add(:project, "must own the source and pull request") unless [ issue, pull_request ].all? { |record| record&.project_id == project_id }
    errors.add(:account, "must own the project") unless project&.account_id == account_id
    errors.add(:authorized_by, "must belong to the account") unless authorized_by&.account_id == account_id
  end

  def merged_pull_request
    return if pull_request.blank? || (pull_request.is_pull_request? && pull_request.github_state == "closed" && pull_request.pr_review_phase == "merged")
    errors.add(:pull_request, "must be a merged pull request")
  end

  def canonical_pull_request_identity
    return if pull_request.blank?
    return if pull_request_url == canonical_pull_request_url &&
      pull_request.github_html_url == canonical_pull_request_url

    errors.add(:pull_request_url, "must be the pull request's canonical GitHub URL")
  end

  def canonical_pull_request_url
    self.class.canonical_url_for(pull_request)
  end
end
