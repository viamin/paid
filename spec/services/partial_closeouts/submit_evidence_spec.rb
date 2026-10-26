# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:actor) { create(:user, account:) }

  it "records a durable link as pending validation with criterion, revision, actor, and explanation" do # @spec PARTIAL-CLOSEOUT-030
    allow(Issues::CloseoutEvidence).to receive(:call).with(issue).and_return(instance_double(Issues::CloseoutEvidence::Result, digest: "revision-1"))

    result = described_class.call(issue:, actor:, criterion: "pilot sign-off", evidence_type: "link",
      evidence_reference: "https://example.test/pilot", source_revision: "revision-1", explanation: "Pilot owner recorded the result.")

    expect(result).to be_success
    expect(result.submission).to have_attributes(status: "submitted", criterion: "pilot sign-off", source_revision: "revision-1", actor:)
    expect(result.submission.reasoning).to include("pending validation")
  end

  it "marks an old evidence generation stale instead of accepting it" do # @spec PARTIAL-CLOSEOUT-030
    allow(Issues::CloseoutEvidence).to receive(:call).with(issue).and_return(instance_double(Issues::CloseoutEvidence::Result, digest: "revision-2"))

    result = described_class.call(issue:, actor:, criterion: "pilot sign-off", evidence_type: "link",
      evidence_reference: "https://example.test/pilot", source_revision: "revision-1", explanation: "Pilot owner recorded the result.")

    expect(result).to be_success
    expect(result.submission).to have_attributes(status: "stale", source_revision: "revision-1")
  end
end
