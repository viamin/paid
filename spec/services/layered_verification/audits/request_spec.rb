# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  include ActiveJob::TestHelper

  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-013 LAYERED-VERIFY-024
  it "queues an issue-less audit with an executable audit prompt" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    run = nil
    expect {
      run = described_class.call(
        project:, user:, obligation_ids: [ obligation.id ], target_revision: "abc123",
        budget: { "max_minutes" => 15 },
        selections: { obligation.id => { "selected_checks" => [ "spec_to_code" ] } }
      )
    }.to have_enqueued_job(ProcessRunQueueJob)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, status: "queued")
    expect(run.effective_prompt).to include("Layered-verification audit", "abc123", "spec_to_code")
  end
end
