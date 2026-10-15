# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::TriggerReadinessBootstrap do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:, created_by: user, tdd_mode: "strict") }
  let(:tool) { described_class.new(user:, session:) }

  before do
    project.update!(readiness_gaps: [
      { "kind" => "missing_ci", "description" => "CI is required.", "evidence" => {} }
    ])
  end

  describe "#call" do
    it "queues one confirmed bootstrap run with the current readiness gaps and normal accounting" do # @spec PROJECT-READINESS-007
      result = nil

      expect {
        result = tool.call(project_id: project.id, confirmed: true)
      }.to change(AgentRun, :count).by(1)

      run = AgentRun.find(result[:id])
      expect(run).to have_attributes(
        goal: "bootstrap_readiness",
        trigger_type: "manual",
        status: "queued",
        tokens_input: 0,
        tokens_output: 0
      )
      expect(run.custom_prompt).to include("CI is required.")
      expect(ProcessRunQueueJob).to have_been_enqueued
    end

    it "requires explicit confirmation" do # @spec PROJECT-READINESS-007
      expect {
        tool.call(project_id: project.id)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "authorizes the project before triggering bootstrap" do # @spec PROJECT-READINESS-007
      viewer = create(:user, :viewer, account:)
      viewer_tool = described_class.new(user: viewer, session:)

      expect {
        viewer_tool.call(project_id: project.id, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "requires a current project setup pending entry" do # @spec PROJECT-READINESS-007
      project.update!(readiness_gaps: [])

      expect {
        tool.call(project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, "This project no longer needs bootstrap setup.")
    end

    it "does not queue a second unfinished bootstrap attempt" do # @spec PROJECT-READINESS-007
      create(:agent_run, :running, project:, goal: "bootstrap_readiness")

      expect {
        tool.call(project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, "A bootstrap attempt is already in progress for this project.")
    end

    it "permits an explicit retrigger after failure without changing the failure reason" do # @spec PROJECT-READINESS-007
      failed_run = create(:agent_run, :failed, project:, goal: "bootstrap_readiness", error_message: "Missing CI credential")

      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:id]).not_to eq(failed_run.id)
      expect(failed_run.reload.error_message).to eq("Missing CI credential")
    end
  end
end
