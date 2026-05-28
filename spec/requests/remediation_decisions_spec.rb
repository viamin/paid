# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RemediationDecisions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:decision) do
    create(
      :remediation_decision,
      account: account,
      proposed_action: "disable_runner_fallback",
      action_target_type: "runner",
      action_target_id: "42"
    )
  end

  before { sign_in user }

  describe "GET /remediation_decisions/:id" do
    it "renders the remediation decision details" do
      get remediation_decision_path(decision)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Remediation Decision ##{decision.id}")
      expect(response.body).to include("Disable runner fallback")
      expect(response.body).to include("Runner #42")
      expect(response.body).to include(decision.root_cause)
    end
  end
end
