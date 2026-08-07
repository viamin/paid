# frozen_string_literal: true

require "rails_helper"
require "temporalio/client"

RSpec.describe StyleGuideEvolutionJob do
  let(:job) { described_class.new }
  let(:temporal_client) { instance_double(Temporalio::Client) }
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)
    allow(temporal_client).to receive(:start_workflow)
  end

  def create_exposure(style_guide:, project:, created_at: 1.day.ago)
    agent_run = create(:agent_run, project: project)
    create(
      :style_guide_run_exposure,
      style_guide: style_guide,
      style_guide_version: style_guide.current_version,
      agent_run: agent_run,
      created_at: created_at
    )
  end

  def create_running_ab_test(style_guide:, account:)
    running_test = create(
      :style_guide_ab_test,
      account: account,
      style_guide: style_guide,
      control_version: style_guide.current_version,
      status: "draft"
    )
    running_test.style_guide_ab_test_variants.create!(
      style_guide_version: style_guide.current_version,
      is_control: true
    )
    running_test.start!
  end

  it "skips global guides when scheduling evolution" do
    global_guide = create(:style_guide, :global)
    create_exposure(style_guide: global_guide, project: project)

    job.perform

    expect(temporal_client).not_to have_received(:start_workflow).with(
      Workflows::StyleGuideEvolutionWorkflow,
      hash_including(style_guide_id: global_guide.id),
      anything
    )
  end

  it "skips accounts that already have a running style guide A/B test" do
    running_guide = create(:style_guide, account: account, project: nil)
    blocked_guide = create(:style_guide, account: account, project: nil)
    create_exposure(style_guide: blocked_guide, project: project)

    create_running_ab_test(style_guide: running_guide, account: account)

    job.perform

    expect(temporal_client).not_to have_received(:start_workflow).with(
      Workflows::StyleGuideEvolutionWorkflow,
      hash_including(style_guide_id: blocked_guide.id),
      anything
    )
  end

  # @spec STYLE-GUIDE-EVOLUTION-009
  it "starts a workflow for an eligible account-level guide" do
    style_guide = create(:style_guide, account: account, project: nil)
    create_exposure(style_guide: style_guide, project: project)

    job.perform

    expect(temporal_client).to have_received(:start_workflow).with(
      Workflows::StyleGuideEvolutionWorkflow,
      hash_including(style_guide_id: style_guide.id, project_id: nil),
      hash_including(id: "style-guide-evolution-#{account.id}-#{style_guide.id}-#{Date.current}")
    )
  end
end
