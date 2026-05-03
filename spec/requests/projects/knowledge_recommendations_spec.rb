# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::KnowledgeRecommendations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  before { sign_in user }

  describe "GET /projects/:project_id/knowledge_recommendations" do
    it "shows the recommendations index" do
      create(:knowledge_recommendation, project: project, status: "pending", priority: "high")
      create(:knowledge_recommendation, project: project, status: "accepted")

      get project_knowledge_recommendations_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Knowledge Recommendations")
    end
  end

  describe "PATCH /projects/:project_id/knowledge_recommendations/:id" do
    let!(:recommendation) { create(:knowledge_recommendation, project: project, status: "pending") }

    context "when user has update permission" do
      before { user.add_role(:admin, account) }

      it "accepts a recommendation" do
        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "accept"
        }

        expect(response).to redirect_to(project_knowledge_recommendations_path(project))
        expect(recommendation.reload.status).to eq("accepted")
      end

      it "dismisses a recommendation with a reason" do
        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "dismiss",
          dismissal_reason: "Not relevant"
        }

        expect(response).to redirect_to(project_knowledge_recommendations_path(project))
        expect(recommendation.reload.status).to eq("dismissed")
        expect(recommendation.dismissal_reason).to eq("Not relevant")
      end

      it "responds with turbo_stream" do
        patch project_knowledge_recommendation_path(project, recommendation),
          params: { action_type: "accept" },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      end
    end
  end
end
