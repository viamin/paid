# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationObligation do
  # @spec LAYERED-VERIFY-006
  it "requires a stable project-scoped canonical reference and authority state" do
    obligation = described_class.new(project: create(:project))

    expect(obligation).to be_invalid
    expect(obligation.errors.attribute_names).to include(:framework, :external_identity, :scope_description)
    expect(obligation.approval_state).to eq("unresolved")
  end

  # @spec LAYERED-VERIFY-004
  it "does not treat a ChangeIntent activation as repository-persisted approval" do
    intent = create(:change_intent, :draft)
    obligation = create(:layered_verification_obligation, :offered_cir, project: intent.project, change_intent: intent)

    intent.activate!

    expect { obligation.record_approval!(revision: "abc123", approval_reference: "pr#1", persisted: false) }
      .to raise_error(LayeredVerificationObligation::ApprovalNotPersistedError)
    expect(obligation.reload).to have_attributes(approval_state: "proposed", approved_revision_reference: nil)
  end

  # @spec LAYERED-VERIFY-004
  it "records approval only with repository persistence" do
    obligation = create(:layered_verification_obligation, :offered_cir)

    obligation.record_approval!(revision: "abc123", approval_reference: "pr#1", persisted: true)

    expect(obligation.reload).to have_attributes(
      approval_state: "approved", external_revision: "abc123", approved_revision_reference: "pr#1"
    )
  end
end
