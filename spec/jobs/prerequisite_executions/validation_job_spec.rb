# frozen_string_literal: true

require "rails_helper"

# @spec PREREQ-EXEC-006
RSpec.describe PrerequisiteExecutions::ValidationJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:validation) { create(:prerequisite_execution_validation, :with_agent_run, project: project, issue: issue) }

  it "executes the claimed attempt through the runner inside the project tenant context" do
    runner = instance_double(PrerequisiteExecutions::Runner)
    allow(PrerequisiteExecutions::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call)

    described_class.perform_now(validation.id)

    expect(PrerequisiteExecutions::Runner).to have_received(:new).with(validation)
    expect(runner).to have_received(:call)
  end

  it "discards when the attempt no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
