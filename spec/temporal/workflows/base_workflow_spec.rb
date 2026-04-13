# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::BaseWorkflow do
  let(:workflow_class) do
    Class.new(described_class) do
      def execute(input)
        [
          feature_flag_enabled?(:explicit_pr_automation_decisions, project_id: input[:project_id]),
          feature_flag_enabled?(:explicit_pr_automation_decisions, project_id: input[:project_id])
        ]
      end
    end
  end

  let(:workflow) { workflow_class.new }

  describe "#feature_flag_enabled?" do
    it "loads the workflow flag snapshot through an activity and memoizes it per project" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: 123 }, timeout: 10)
        .and_return(flags: { explicit_pr_automation_decisions: true })

      expect(workflow.execute(project_id: 123)).to eq([ true, true ])
      expect(workflow).to have_received(:run_activity).once
    end
  end
end
