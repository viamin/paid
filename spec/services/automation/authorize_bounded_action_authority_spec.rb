# frozen_string_literal: true

require "rails_helper"

# The bounded-authorization proposal is not live. Its durable write boundary
# exists and is exercised by its own service specs, but no application surface
# calls it, and the phase model stays default-off. Nothing therefore mints
# bounded-phase authority: not a GitHub approval or review, not an agent run,
# and not an ordinary continuation grant.
#
# The implementation slice that adds the consent command (#4997) replaces the
# "no caller" expectation with the accepted surface, because the guard it
# records no longer holds once the proposal is accepted and implemented.
#
# @spec AUTOMATION-PHASES-014 @spec BOUNDED-PHASE-AUTHORIZATION-011
RSpec.describe Automation::AuthorizeBoundedAction do
  let(:source_files) do
    (Dir.glob(Rails.root.join("app/**/*.rb")) + Dir.glob(Rails.root.join("lib/**/*.rb"))).sort
  end

  it "keeps the phase model default-off" do
    definition = FeatureFlags.definition(Automation::RolloutGuard::FLAG)

    expect(definition.name).to eq(:automation_phases)
    expect(definition.rollout_plan).to include("Default-off")
    expect(Automation::RolloutGuard.enabled?(create(:project))).to be(false)
  end

  it "exposes no caller that can mint or revoke a bounded authorization" do
    callers = source_files.select do |path|
      File.read(path).match?(/Automation::(?:Authorize|Revoke)BoundedAction\.call/)
    end

    expect(callers).to eq([])
  end

  it "creates bounded authorizations only through the authorization write boundary" do
    creators = source_files.select do |path|
      File.read(path).match?(/bounded_delegated_actions\.create!?\(|BoundedDelegatedAction\.create!?\(/)
    end

    expect(creators).to eq([ Rails.root.join("app/services/automation/authorize_bounded_action.rb").to_s ])
  end

  it "never treats reserved product, release, or setting decisions as delegable" do
    expect(BoundedDelegatedAction::RESERVED_ACTIONS).to contain_exactly(
      "product_decision", "feature_approval", "release", "deployment", "setting_enablement"
    )
  end
end
