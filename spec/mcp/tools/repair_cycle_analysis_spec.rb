# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RepairCycleAnalysis do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let(:run) { create(:agent_run, :completed, project:, goal: AgentRun::CYCLE_ANALYSIS_GOAL) }
  let(:tool) { described_class.new(user:, session:) }
  let(:repair_result) { Data.define(:status, :message) { def success? = status == :applied }.new(status: :applied, message: "Removed dependency declaration from #12.") }

  it "requires confirmation and returns the bounded repair outcome" do
    run.update!(verification_result: {
      CycleAnalyses::RESULT_KEY => { "recommendation" => { "candidates" => [ { "edge_id" => 42 } ] } }
    })
    allow(CycleAnalyses::Repair).to receive(:call).and_return(repair_result)

    expect {
      tool.call(agent_run_id: run.id, candidate_index: 0, project_id: project.id, confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)

    result = tool.call(agent_run_id: run.id, candidate_index: 0, project_id: project.id, confirmed: true)

    expect(CycleAnalyses::Repair).to have_received(:call).with(
      agent_run: run, candidate: { "edge_id" => 42 }, actor: user
    )
    expect(result).to eq(agent_run_id: run.id, candidate_index: 0, status: "applied",
      message: "Removed dependency declaration from #12.", success: true)
  end

  it "returns non-success repair outcomes without hiding them" do
    run.update!(verification_result: {
      CycleAnalyses::RESULT_KEY => { "recommendation" => { "candidates" => [ { "edge_id" => 42 } ] } }
    })
    allow(CycleAnalyses::Repair).to receive(:call).and_return(
      Data.define(:status, :message) { def success? = false }.new(status: :stale, message: "Analyze again.")
    )

    result = tool.call(agent_run_id: run.id, candidate_index: 0, project_id: project.id, confirmed: true)

    expect(result).to eq(agent_run_id: run.id, candidate_index: 0, status: "stale",
      message: "Analyze again.", success: false)
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
  it "reports incomplete analysis results separately from unavailable candidates" do
    [
      {},
      { CycleAnalyses::RESULT_KEY => {} },
      { CycleAnalyses::RESULT_KEY => { "recommendation" => {} } }
    ].each do |verification_result|
      run.update!(verification_result:)

      expect {
        tool.call(agent_run_id: run.id, candidate_index: 0, project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, /Cycle analysis result is incomplete/)
    end

    run.update!(verification_result: {
      CycleAnalyses::RESULT_KEY => { "recommendation" => { "candidates" => [] } }
    })

    expect {
      tool.call(agent_run_id: run.id, candidate_index: 0, project_id: project.id, confirmed: true)
    }.to raise_error(ArgumentError, "Cycle analysis candidate is no longer available")
  end
end
