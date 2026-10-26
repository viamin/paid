# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  describe ".call" do
    # @spec LAYERED-VERIFY-013
    it "creates an issue-less bounded audit run with its resolved scope and budget" do
      project = create(:project)
      obligation = create(:layered_verification_obligation, project: project)
      allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])

      run = described_class.call(project:, user: project.created_by, obligations: [ obligation ], budget: 1234)

      expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: project.created_by)
      expect(run.external_metadata).to include("obligation_ids" => [ obligation.id ], "budget" => 1234)
    end
  end
end
