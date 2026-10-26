# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let(:obligation) { create(:layered_verification_obligation, project:) }
  let(:tool) { described_class.new(user:, session:) }
  let(:selections) do
    {
      obligation.id => {
        selected_checks: [ "spec_to_code" ],
        fit: "mapped specification",
        exclusions: [ "no formal model" ]
      }
    }
  end

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  # @spec LAYERED-VERIFY-014 LAYERED-VERIFY-021
  it "preserves obligation IDs and selected plan fields across confirmation" do
    preview = tool.dispatch(
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      target_revision: "abc123",
      budget: { max_minutes: 15 },
      selections:
    )

    expect(preview.fetch("plan")).to have_key(obligation.id.to_s)

    result = tool.resolve_confirmation(decision: :approve, pending_result: preview)
    run = AgentRun.find(result.fetch(:id))
    stored_plan = run.external_metadata.dig("layered_verification", "plan", obligation.id.to_s)

    expect(stored_plan).to include(
      "selected_checks" => [ "spec_to_code" ],
      "fit" => "mapped specification",
      "exclusions" => [ "no formal model" ]
    )
  end
end
