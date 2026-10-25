# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

RSpec.describe Prerequisites::StartValidation do # @spec PREREQ-EVIDENCE-002 @spec PREREQ-EVIDENCE-004
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project, github_state: "open") }

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(PrerequisiteValidationJob).to receive(:perform_later)
  end

  def enable_tool_sidecars!(enabled)
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(enabled)
  end

  it "creates a pending validation scoped to the issue and enqueues the executor" do
    enable_tool_sidecars!(true)

    result = described_class.call(issue: issue, actor: user)

    expect(result).to be_success
    validation = result.validation
    expect(validation.status).to eq("pending")
    expect(validation.project).to eq(project)
    expect(validation.requested_by).to eq(user)
    expect(validation.include_tool_sidecar).to be(true)
    expect(validation.scope_digest).to be_present
    expect(validation.capability_snapshot["tool_sidecars_enabled"]).to be(true)
    expect(PrerequisiteValidationJob).to have_received(:perform_later).with(validation.id)
  end

  it "snapshots the default analyzer command when none is supplied" do
    enable_tool_sidecars!(true)

    result = described_class.call(issue: issue, actor: user, analyzer_command: "  ")

    expect(result.validation.analyzer_command).to be_nil
    expect(result.validation.capability_snapshot["analyzer_command"]).to eq(PrerequisiteValidation::DEFAULT_ANALYZER_COMMAND)
  end

  it "records the exact authorized flag action at start when the rollout flag is off" do
    enable_tool_sidecars!(false)

    result = described_class.call(issue: issue, actor: user)

    expect(result).to be_success
    expect(result.validation.blockers).to contain_exactly(
      a_hash_including(
        "check" => "tool_sidecar",
        "reason" => a_string_including("flag is off"),
        "authorized_action" => a_string_including("tenant_settings.features")
      )
    )
  end

  it "records the allowlist action at start when the selected tool image is denied" do
    enable_tool_sidecars!(true)
    AccountMembership.find_by!(account: account, user: user).update!(role: :owner)
    create(:user_setting, user: user, allowed_service_images: %w[example/echo:1])
    entry = create(:marketplace_entry, account: account, entry_type: "tool", name: "denied-tool")
    entry.create_version!(canonical_artifact: { "install_type" => "tool", "image" => "denied/image:1", "port" => 8080 })

    result = described_class.call(issue: issue, actor: user)

    expect(result.validation.blockers).to contain_exactly(
      a_hash_including(
        "check" => "tool_sidecar",
        "reason" => a_string_including("denied/image:1"),
        "authorized_action" => a_string_including("allowed service images")
      )
    )
  end

  it "refuses a second validation while one is active" do
    enable_tool_sidecars!(true)
    described_class.call(issue: issue, actor: user)

    result = described_class.call(issue: issue, actor: user)

    expect(result).not_to be_success
    expect(result.code).to eq(:in_progress)
    expect(result.message).to include("already")
  end

  it "checks the project budget before starting" do
    enable_tool_sidecars!(true)
    allow(CostBudgets::Check).to receive(:call).with(project).and_return({ allowed: false, reason: "monthly cap" })

    result = described_class.call(issue: issue, actor: user)

    expect(result).not_to be_success
    expect(result.code).to eq(:budget_exhausted)
    expect(PrerequisiteValidation).not_to exist
  end

  it "treats a start after a terminal validation as a new generation" do
    enable_tool_sidecars!(true)
    first = described_class.call(issue: issue, actor: user).validation
    first.update!(status: "unavailable", completed_at: Time.current)

    second = described_class.call(issue: issue, actor: user)

    expect(second.validation.id).not_to eq(first.id)
    expect(PrerequisiteValidation.where(issue: issue).count).to eq(2)
    expect(first.reload.result).to eq({})
  end
end
