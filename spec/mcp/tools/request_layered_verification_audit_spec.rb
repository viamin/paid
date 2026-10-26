# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let!(:obligation) { create(:layered_verification_obligation, project:) }

  before { allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true) }

  it "uses the shared audit request and requires a human confirmation" do # @spec LAYERED-VERIFY-014
    tool = described_class.new(user:, session:)
    expect { tool.call(project_id: project.id, obligation_ids: [ obligation.id ], budget: 1000) }
      .to raise_error(ArgumentError, /Confirmation required/)

    result = tool.call(project_id: project.id, obligation_ids: [ obligation.id ], budget: 1000, confirmed: true)
    expect(result).to include(goal: "layered_verification_audit", project_id: project.id, status: "queued")
  end
end
