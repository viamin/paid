# frozen_string_literal: true

class ProjectConventionRecommendation < ApplicationRecord
  AUTO_DISMISSAL_REASON = "Convention no longer detected"
  ACTION_TYPES = %w[apply_in_paid open_pr apply_github_side manual_review].freeze
  STATUSES = %w[pending applied dismissed].freeze

  belongs_to :project
  belongs_to :dismissed_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true

  validates :convention_key, presence: true, length: { maximum: 100 }
  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :title, presence: true, length: { maximum: 255 }
  validates :description, presence: true
  validates :dismissal_reason, presence: true, if: :dismissed?

  scope :pending, -> { where(status: "pending") }
  scope :resolved, -> { where.not(status: "pending") }
  scope :by_recency, -> { order(generated_at: :desc, created_at: :desc) }

  def dismiss!(dismissed_by:, reason:)
    update!(
      status: "dismissed",
      dismissed_by: dismissed_by,
      dismissed_at: Time.current,
      dismissal_reason: reason
    )
  end

  def apply!(applied_by:)
    update!(
      status: "applied",
      applied_by: applied_by,
      applied_at: Time.current
    )
  end

  def reopen!(attributes = {})
    update!(
      {
        status: "pending",
        dismissed_by: nil,
        dismissed_at: nil,
        dismissal_reason: nil
      }.merge(attributes)
    )
  end

  def pending?
    status == "pending"
  end

  def dismissed?
    status == "dismissed"
  end

  def applied?
    status == "applied"
  end

  def resolved?
    status.in?(%w[applied dismissed])
  end

  def apply_in_paid?
    action_type == "apply_in_paid"
  end

  def open_pr?
    action_type == "open_pr"
  end

  def applyable_via_paid?
    apply_in_paid? || open_pr?
  end

  def auto_dismissed?
    dismissed? && dismissed_by_id.nil? && dismissal_reason == AUTO_DISMISSAL_REASON
  end

  def pull_request_url
    evidence.is_a?(Hash) ? evidence["pull_request_url"] : nil
  end

  def record_pull_request_url!(url)
    update!(evidence: evidence.merge("pull_request_url" => url))
  end

  def open_pr_application_in_progress?
    return false unless open_pr?

    if ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::TestAdapter)
      ActiveJob::Base.queue_adapter.enqueued_jobs.any? do |job|
        job[:job] == ProjectConventions::OpenHookGuardrailPullRequestJob &&
          job[:args].second == id
      end
    else
      GoodJob::Job.where(
        concurrency_key: ProjectConventions::OpenHookGuardrailPullRequestJob.concurrency_key_for(id),
        finished_at: nil
      ).exists?
    end
  end
end
