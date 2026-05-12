# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveCoordinationExperimentActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) do
    create(:coordination_experiment,
      account: account,
      control_policy: {
        "parallel_execution" => { "max_batch_size" => 3, "cancel_remaining_on_failure" => false },
        "decomposition" => { "enabled" => true, "max_tasks" => 6 }
      })
  end
  let!(:variant) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: { "parallel_execution" => { "max_batch_size" => 1 } })
  end

  def assignment
    create(:coordination_experiment_assignment,
      coordination_experiment: experiment,
      coordination_experiment_variant: variant,
      project: project,
      issue: issue)
  end

  def expect_merged_policy!(result)
    expect(result).to include(
      experiment_id: experiment.id,
      variant_id: variant.id,
      coordination_policy: {
        "parallel_execution" => {
          "max_batch_size" => 1,
          "cancel_remaining_on_failure" => false
        },
        "decomposition" => {
          "enabled" => true,
          "max_tasks" => 6
        }
      }
    )
  end

  it "returns a baseline-merged policy for the assigned variant" do
    allow(CoordinationExperiment).to receive(:active_for).and_return(experiment)
    allow(CoordinationExperiments::Assign).to receive(:call).and_return(assignment)

    result = activity.execute(project_id: project.id, issue_id: issue.id, workflow_id: "wf-123")

    expect_merged_policy!(result)
  end
end
