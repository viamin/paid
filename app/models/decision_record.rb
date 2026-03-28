# frozen_string_literal: true

class DecisionRecord < ApplicationRecord
  STATUSES = %w[draft active superseded reverted].freeze
  CONTENT_FIELDS = %w[title summary context decision consequences tags commit_sha_start commit_sha_end].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :issue, optional: true
  belongs_to :superseded_by, class_name: "DecisionRecord", optional: true

  has_many :decision_record_links, dependent: :destroy
  has_many :supersedes, class_name: "DecisionRecord", foreign_key: :superseded_by_id,
    inverse_of: :superseded_by, dependent: :nullify

  before_update :enforce_immutability

  validates :title, presence: true, length: { maximum: 500 }
  validates :summary, presence: true
  validates :decision, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :commit_sha_start, length: { maximum: 40 }
  validates :commit_sha_end, length: { maximum: 40 }
  validate :agent_run_belongs_to_same_project, if: -> { agent_run.present? }
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :superseded_by_belongs_to_same_project, if: -> { superseded_by.present? }

  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(status: "draft") }
  scope :for_project, ->(project) { where(project: project) }
  scope :by_status, ->(status) { where(status: status) }

  def activate!
    update!(status: "active")
  end

  def supersede!(new_record)
    transaction do
      update!(status: "superseded", superseded_by: new_record)
    end
  end

  def revert!
    update!(status: "reverted")
  end

  private

  def agent_run_belongs_to_same_project
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def superseded_by_belongs_to_same_project
    return if superseded_by.project_id == project_id

    errors.add(:superseded_by, "must belong to the same project")
  end

  def enforce_immutability
    return if new_record?

    changed_content = changed & CONTENT_FIELDS
    return if changed_content.empty?

    changed_content.each do |field|
      errors.add(field, "is immutable after creation")
    end

    throw :abort
  end
end
