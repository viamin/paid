# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationExperiments::Assign do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) { create(:coordination_experiment, account: account, status: "running") }
  let!(:control) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: experiment.control_policy,
      is_control: true)
  end
  let!(:variant) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: experiment.control_policy.merge("parallel_execution" => { "max_batch_size" => 1 }))
  end

  it "creates a workflow-scoped assignment" do
    assignment = described_class.call(
      coordination_experiment: experiment,
      project: project,
      issue: issue,
      workflow_id: "wf-123"
    )

    expect(assignment.project).to eq(project)
    expect(assignment.issue).to eq(issue)
    expect(assignment.workflow_id).to eq("wf-123")
    expect([ control, variant ]).to include(assignment.coordination_experiment_variant)
  end

  it "reuses the existing assignment for the same workflow" do
    first = described_class.call(coordination_experiment: experiment, project: project, workflow_id: "wf-123")
    second = described_class.call(coordination_experiment: experiment, project: project, workflow_id: "wf-123")

    expect(second.id).to eq(first.id)
  end

  it "balances across variants" do
    assignments = 6.times.map do |index|
      described_class.call(
        coordination_experiment: experiment,
        project: project,
        workflow_id: "wf-#{index}"
      )
    end

    counts = assignments.map(&:coordination_experiment_variant_id).tally

    expect(counts.keys.size).to eq(2)
    counts.each_value { |count| expect(count).to be_between(2, 4) }
  end
end
