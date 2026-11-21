# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-005
RSpec.describe Automation::ResolveBoundedReassessment do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:authorization) { create(:bounded_delegated_action, account:, project:, created_by: user) }

  before { authorization.require_reassessment!(reasons: [ :intent_revision ]) }

  it "resumes only after revalidation and retains the original pinned evidence" do
    original_evidence = authorization.evidence.deep_dup

    expect { described_class.call(authorization:, user:, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /revalidation/)
    expect(described_class.call(authorization:, user:, resolution: :resume, revalidated: true)).to eq(:resumed)
    expect(authorization.reload).to be_active
    expect(authorization.evidence).to eq(original_evidence)
    expect(AccountActivityEvent.last.action).to eq("bounded_action.reassessment_resumed")
  end

  it "lets an authorized actor stop a reassessment-required authorization" do
    expect(described_class.call(authorization:, user:, resolution: :stop)).to eq(:stopped)
    expect(authorization.reload).to be_revoked
  end
end
