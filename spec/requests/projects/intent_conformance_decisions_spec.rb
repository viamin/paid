# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-004
RSpec.describe "Projects::IntentConformanceDecisions" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, :pull_request, project: project, github_number: 7) }
  let!(:verdict) { create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1") }

  before { sign_in owner }

  describe "POST /projects/:project_id/intent_conformance_decisions" do
    it "records a bounded exception with the actor and reason, then redirects" do
      post project_intent_conformance_decisions_path(project),
        params: { verdict_id: verdict.id, action_type: "bounded_exception", reason: "Implementation detail only." }

      decision = IntentConformanceDecision.last
      expect(decision).to have_attributes(
        issue_id: issue.id,
        verdict_id: verdict.id,
        action: "bounded_exception",
        head_sha: "sha1",
        reason: "Implementation detail only.",
        actor_id: owner.id
      )
      expect(response).to redirect_to(dashboard_path)
      follow_redirect!
      expect(response.body).to include("Decision recorded")
    end

    it "redirects with an alert when the verdict cannot be found for this project" do
      post project_intent_conformance_decisions_path(project),
        params: { verdict_id: 0, action_type: "fix_pr", reason: "reason" }

      expect(response).to redirect_to(dashboard_path)
      follow_redirect!
      expect(response.body).to include("Please select an intent-conformance decision")
    end

    it "redirects with an alert when the decision fails validation" do
      post project_intent_conformance_decisions_path(project),
        params: { verdict_id: verdict.id, action_type: "not_a_real_action", reason: "reason" }

      expect(response).to redirect_to(dashboard_path)
      follow_redirect!
      expect(response.body).to include("Could not record the decision")
    end

    it "denies a user without run_agent access" do
      outsider = create(:user)

      sign_in outsider

      post project_intent_conformance_decisions_path(project),
        params: { verdict_id: verdict.id, action_type: "fix_pr", reason: "reason" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
