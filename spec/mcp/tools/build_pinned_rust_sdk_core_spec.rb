# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::BuildPinnedRustSdkCore do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:agent_run) { create(:agent_run, project:, initiating_user: user) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:, agent_run:) }

  before do
    create(:project_membership, :member, user:, project:)
    agent_run.update!(external_metadata: { "planned_container_host" => "local" })
  end

  # @spec RUST-SDK-BUILD-013
  it "uses the acting run's selected backend without exposing Docker to the caller" do
    backend = instance_double(Containers::Backends::LocalDocker)
    receipt = { exit_status: 0 }
    allow(Containers).to receive(:backend_for).with("local").and_return(backend)
    allow(SdkBuildEnvironments::PinnedCoreBuild).to receive(:call).with(backend:).and_return(receipt)

    expect(tool.call(project_id: project.id, agent_run_id: agent_run.id, confirmed: true)).to eq(receipt)
    expect(SdkBuildEnvironments::PinnedCoreBuild).to have_received(:call).with(backend:)
  end

  # @spec RUST-SDK-BUILD-013
  it "requires explicit confirmation" do
    expect {
      tool.call(project_id: project.id, agent_run_id: agent_run.id)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  # @spec RUST-SDK-BUILD-013
  it "refuses to substitute the local backend when the run has not selected one" do
    agent_run.update!(container_host: nil, external_metadata: {})

    expect {
      tool.call(project_id: project.id, agent_run_id: agent_run.id, confirmed: true)
    }.to raise_error(ArgumentError, /no selected container backend/)
  end
end
