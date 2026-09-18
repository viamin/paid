# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveReviewPipelineActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, goal: "review", source_pull_request_number: 7) }
  let(:activity) { described_class.new }

  def resolve(agent_run_id)
    activity.execute({ agent_run_id: agent_run_id })
  end

  # @spec REVIEW-VERIFY-001
  it "selects the verified pipeline when the pilot flag and paid_agent are enabled" do
    allow(project).to receive_messages(
      review_enabled?: true,
      review_method_enabled?: true,
      paid_agent_independent_verification?: true
    )

    expect(resolve(agent_run.id)).to eq(pipeline: "verified")
  end

  # @spec REVIEW-VERIFY-001
  it "selects the container pipeline when the pilot flag is off" do
    allow(project).to receive_messages(
      review_enabled?: true,
      review_method_enabled?: true,
      paid_agent_independent_verification?: false
    )

    expect(resolve(agent_run.id)).to eq(pipeline: "container")
  end

  it "selects the container pipeline for non-review goals even with the flag on" do
    create_run = create(:agent_run, project: project, goal: "create_pr")
    allow(project).to receive(:paid_agent_independent_verification?).and_return(true)

    expect(resolve(create_run.id)).to eq(pipeline: "container")
  end
end
