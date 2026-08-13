# frozen_string_literal: true

class AgentCoordinationSignal < ApplicationRecord
  SIGNAL_TYPES = %w[
    files_changed
    dependency_completed
    dependency_failed
    context_shared
    sequencing_hint
  ].freeze

  belongs_to :source_agent_run, class_name: "AgentRun"
  belongs_to :target_agent_run, class_name: "AgentRun", optional: true

  validates :parent_workflow_id, presence: true, length: { maximum: 255 }
  validates :signal_type, presence: true, inclusion: { in: SIGNAL_TYPES }

  scope :for_workflow, ->(workflow_id) { where(parent_workflow_id: workflow_id) }
  scope :for_target, ->(agent_run) { where(target_agent_run: agent_run) }
  scope :by_type, ->(type) { where(signal_type: type) }
  scope :broadcast_signals, -> { where(target_agent_run_id: nil) }

  # Returns all signals visible to a given agent run: targeted signals plus
  # broadcasts within the same workflow.
  scope :visible_to, ->(agent_run) {
    where(parent_workflow_id: agent_run.parent_workflow_id)
      .where("target_agent_run_id = ? OR target_agent_run_id IS NULL", agent_run.id)
  }

  # Returns changed files reported by completed sibling runs within a workflow.
  def self.changed_files_for_workflow(parent_workflow_id)
    for_workflow(parent_workflow_id)
      .by_type("files_changed")
      .pluck(:payload)
      .flat_map { |p| Array(p["files"]) }
      .uniq
  end

  # Returns sequencing hints for a target run, ordered by creation time.
  def self.sequencing_hints_for(agent_run)
    visible_to(agent_run)
      .by_type("sequencing_hint")
      .order(:created_at)
  end

  # Checks whether all dependencies for a target run have been satisfied.
  # A dependency is satisfied when a `dependency_completed` signal exists
  # from each required source run.
  def self.dependencies_met?(agent_run, required_run_ids:)
    return true if required_run_ids.empty?

    completed_ids = for_workflow(agent_run.parent_workflow_id)
      .by_type("dependency_completed")
      .where(source_agent_run_id: required_run_ids)
      .where("target_agent_run_id = ? OR target_agent_run_id IS NULL", agent_run.id)
      .distinct
      .pluck(:source_agent_run_id)

    (required_run_ids.map(&:to_i) - completed_ids).empty?
  end

  # Checks whether any dependency for a target run has failed.
  def self.any_dependency_failed?(agent_run, required_run_ids:)
    return false if required_run_ids.empty?

    for_workflow(agent_run.parent_workflow_id)
      .by_type("dependency_failed")
      .where(source_agent_run_id: required_run_ids)
      .where("target_agent_run_id = ? OR target_agent_run_id IS NULL", agent_run.id)
      .exists?
  end
end
