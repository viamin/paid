# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-001
# @spec POST-DEPLOY-004
RSpec.describe PostDeployMeasurements::Request do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:actor) { create(:user, account: account) }
  let(:check) { PostDeployMeasurements::Registry.find("planning_hold_notifications_actionable") }

  it "creates a pending request bound to issue, criterion, check version, and account" do
    result = described_class.call(issue: issue, check_key: check.key,
      criterion: "Verify the 36 closed holds are no longer actionable.", actor: actor)

    expect(result).to be_created
    measurement = result.measurement
    expect(measurement).to have_attributes(
      status: "pending",
      check_key: check.key,
      check_version: check.version,
      deployed_revision: "",
      account: account,
      project: project,
      issue: issue,
      criterion: "Verify the 36 closed holds are no longer actionable.",
      prerequisite_identity: nil
    )
    expect(measurement.details["check"]).to include("baseline" => 36, "target" => 0)
  end

  it "is idempotent for duplicate requests and events" do
    first = described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: actor)
    second = described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: actor)

    expect(second).not_to be_created
    expect(second.measurement.id).to eq(first.measurement.id)
    expect(issue.post_deploy_measurements.count).to eq(1)
  end

  it "starts a fresh evidence row once the previous generation executed" do
    executed = described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: actor).measurement
    executed.update!(deployed_revision: "pr-7@2026-11-07T00:00:00Z", status: "passed")

    result = described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: actor)

    expect(result).to be_created
    expect(result.measurement.id).not_to eq(executed.id)
    expect(issue.post_deploy_measurements.count).to eq(2)
  end

  it "rejects checks outside the allowlist" do
    expect {
      described_class.call(issue: issue, check_key: "run_arbitrary_sql", criterion: "criterion", actor: actor)
    }.to raise_error(PostDeployMeasurements::Registry::UnknownCheck)
  end

  it "rejects a blank criterion" do
    expect {
      described_class.call(issue: issue, check_key: check.key, criterion: "  ", actor: actor)
    }.to raise_error(ArgumentError, /criterion/)
  end

  it "rejects an actor outside the measurement's account" do
    outsider = create(:user)

    expect {
      described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: outsider)
    }.to raise_error(described_class::Unauthorized, /account/)
  end

  it "keeps the first bound prerequisite identity across duplicate requests" do
    identity = Digest::SHA256.hexdigest("occurrence")
    described_class.call(issue: issue, check_key: check.key, criterion: "criterion",
      actor: actor, prerequisite_identity: identity)
    second = described_class.call(issue: issue, check_key: check.key, criterion: "criterion", actor: actor)

    expect(second.measurement.prerequisite_identity).to eq(identity)
  end
end
