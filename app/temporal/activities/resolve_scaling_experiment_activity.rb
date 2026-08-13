# frozen_string_literal: true

module Activities
  class ResolveScalingExperimentActivity < BaseActivity
    activity_name "ResolveScalingExperiment"

    def execute(input)
      project = Project.find(input[:project_id])
      workflow_id = input[:workflow_id].to_s
      task_count = input[:task_count].to_i
      issue = input[:issue_id] ? project.issues.find(input[:issue_id]) : nil

      learned_allocation = resolve_learned_allocation(project:, task_count:)
      assignments = ScalingExperiment.running
        .where(project: project)
        .order(:id)
        .filter_map do |experiment|
        next unless experiment.includes_traffic?(workflow_id:)
        next unless experiment.matches_context?(task_count:)

        assignment = ScalingExperiments::Assign.call(
          scaling_experiment: experiment,
          project: project,
          issue: issue,
          workflow_id: workflow_id,
          task_count: task_count
        )
        next unless assignment

        {
          assignment_id: assignment.id,
          scaling_experiment_id: experiment.id,
          dimension: experiment.dimension,
          assigned_value: assignment.assigned_value,
          execution_plan: assignment.execution_plan
        }
      end

      {
        assignment_ids: assignments.map { |assignment| assignment[:assignment_id] },
        assignments: assignments,
        learned_allocation: serialize_allocation(learned_allocation)
      }
    end

    private

    def resolve_learned_allocation(project:, task_count:)
      allocation = Scaling::ResourceAllocator.call(
        inputs: Scaling::AllocationInputs.new(task_count: task_count, max_agent_count: task_count),
        observations: ScalingObservation.for_project(project)
          .by_observation_type("feature_orchestration")
          .recent
          .to_a,
        experiment_summaries: ScalingExperiment
          .where(project: project, status: %w[running completed])
          .where.not(cached_summary: nil)
          .pluck(:cached_summary)
      )

      allocation unless allocation.source == :fallback
    end

    def serialize_allocation(allocation)
      return unless allocation

      {
        agent_count: allocation.agent_count,
        max_iterations: allocation.max_iterations,
        parallelism_level: allocation.parallelism_level,
        source: allocation.source,
        reason: allocation.reason,
        metrics: allocation.metrics
      }
    end
  end
end
