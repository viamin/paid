# frozen_string_literal: true

class ContextIntakeQuestion < ApplicationRecord
  STATUSES = %w[pending_review approved archived].freeze

  belongs_to :project, optional: true

  validates :key, presence: true, length: { maximum: 200 }, uniqueness: { scope: :project_id }
  validates :question_text, presence: true
  validates :section_key, presence: true, length: { maximum: 100 }
  validates :section_title, presence: true, length: { maximum: 200 }
  validates :category, presence: true, length: { maximum: 100 }
  validates :round, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :section_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :display_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :provenance, presence: true, inclusion: { in: ContextIntakeResponse::PROVENANCES }

  scope :active, -> { where(active: true) }
  scope :approved, -> { where(status: "approved") }
  scope :global_catalog, -> { where(project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }

  def self.visible_for(project)
    project_ids = [ nil ]
    project_ids << project.id if project

    active
      .approved
      .where(project_id: project_ids)
      .order(:round, :section_order, :display_order, :created_at, :id)
  end

  def approved?
    status == "approved"
  end

  def to_question_hash
    {
      key: key,
      text: question_text,
      required: required,
      section_key: section_key,
      section_title: section_title,
      category: category,
      round: round,
      section_order: section_order,
      display_order: display_order,
      is_follow_up: is_follow_up,
      parent_question_key: parent_question_key,
      conditions: conditions.deep_dup,
      validation_rules: validation_rules.deep_dup,
      provenance: provenance,
      status: status,
      metadata: metadata.deep_dup
    }
  end
end
