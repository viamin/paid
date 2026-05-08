# frozen_string_literal: true

require "rails_helper"

RSpec.describe BundleOutcome do
  it { is_expected.to belong_to(:configuration_bundle) }
  it { is_expected.to belong_to(:agent_run) }
  it { is_expected.to belong_to(:project) }

  it "syncs the project from the agent run" do
    outcome = build(:bundle_outcome, project: nil)

    expect(outcome).to be_valid
    expect(outcome.project).to eq(outcome.agent_run.project)
  end

  it "rejects a bundle from another account" do
    project = create(:project)
    other_bundle = create(:configuration_bundle)
    outcome = build(:bundle_outcome, configuration_bundle: other_bundle, agent_run: create(:agent_run, :completed, project:), project:)

    expect(outcome).not_to be_valid
    expect(outcome.errors[:configuration_bundle]).to include("must belong to the same account as the project")
  end
end
