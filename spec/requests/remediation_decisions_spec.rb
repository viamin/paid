# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RemediationDecisions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
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

    # @spec RUN-OBSTACLE-004
    it "hides the apply and dismiss controls from a member who cannot update" do
      sign_in create(:user, :member, account: account)

      get remediation_decision_path(decision)

      expect(response.body).not_to include(apply_remediation_decision_path(decision))
      expect(response.body).not_to include(dismiss_remediation_decision_path(decision))
    end
  end

  # @spec RUN-OBSTACLE-004
  describe "POST /remediation_decisions/:id/apply" do
    include ActiveJob::TestHelper

    let(:decision) do
      create(:remediation_decision, account: account, proposed_action: "notify")
    end

    it "queues the apply job and applies the proposed remediation" do
      perform_enqueued_jobs do
        post apply_remediation_decision_path(decision)
      end

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(decision.reload).to have_attributes(status: "applied", applied_by: user)
      expect(decision.applied_at).to be_present
    end

    it "does not apply an already-applied remediation" do
      decision.update!(status: "applied", applied_at: Time.current)

      post apply_remediation_decision_path(decision)

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(flash[:alert]).to include("Only proposed remediations can be applied")
      expect(decision.reload.status).to eq("applied")
    end
  end

  describe "POST /remediation_decisions/:id/revert" do
    include ActiveJob::TestHelper

    let(:runner) { create(:runner, user: user, runner_key: "cursor", enabled_for_fallback: true) }
    let(:tier_model_ids) do
      {
        "low" => "claude-haiku-4-5",
        "mid" => "claude-sonnet-4-6",
        "high" => "claude-opus-4-1"
      }
    end
    let(:decision) do
      create(
        :remediation_decision,
        account: account,
        proposed_action: "clear_runner_field",
        action_target_type: "runner_field",
        action_target_id: runner.id.to_s,
        action_target_metadata: { "field_name" => "tier_model_ids" }
      )
    end

    before do
      create(:llm_model, model_id: "claude-haiku-4-5", provider: "anthropic", tier: "low", capability_score: 7.0)
      create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", capability_score: 8.0)
      create(:llm_model, model_id: "claude-opus-4-1", provider: "anthropic", tier: "high", capability_score: 9.0)

      runner.update!(tier_model_ids: tier_model_ids)
      AgentRunPatterns::ApplyDecision.call(
        decision: decision,
        pattern: AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "enhance_issue",
          severity: :error,
          details: { fingerprint: decision.fingerprint, occurrence_count: 3 }
        )
      )
    end

    it "enqueues a revert job and restores the cleared field" do
      expect(decision.reload).to be_revertable
      expect(runner.reload.tier_model_ids).to be_nil

      perform_enqueued_jobs do
        post revert_remediation_decision_path(decision)
      end

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(runner.reload.tier_model_ids).to eq(tier_model_ids)
      expect(decision.reload.status).to eq("reverted")
    end
  end

  # @spec RUN-OBSTACLE-003
  describe "POST /remediation_decisions/:id/dismiss" do
    it "dismisses a proposal with the operator's reason" do
      post dismiss_remediation_decision_path(decision), params: { dismissal_reason: "Known upstream outage" }

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(decision.reload).to have_attributes(
        status: "dismissed",
        dismissal_reason: "Known upstream outage"
      )
      expect(decision.dismissed_at).to be_present
    end

    it "does not dismiss a proposal without a reason" do
      post dismiss_remediation_decision_path(decision), params: { dismissal_reason: "  " }

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(flash[:alert]).to include("Dismissal reason can't be blank")
      expect(decision.reload).to have_attributes(status: "proposed", dismissal_reason: nil, dismissed_at: nil)
    end

    it "does not dismiss an applied remediation" do
      decision.update!(status: "applied", applied_at: Time.current)

      post dismiss_remediation_decision_path(decision), params: { dismissal_reason: "Too late" }

      expect(response).to redirect_to(remediation_decision_path(decision))
      expect(flash[:alert]).to include("Only proposed remediations can be dismissed")
      expect(decision.reload).to have_attributes(status: "applied", dismissal_reason: nil)
    end
  end
end
