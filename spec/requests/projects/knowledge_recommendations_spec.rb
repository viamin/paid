# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::KnowledgeRecommendations" do
  include ActionView::RecordIdentifier

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/knowledge_recommendations" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_knowledge_recommendations_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        sign_in user
        user.add_role(:admin, account)
      end

      it "shows the recommendations index" do
        create(:knowledge_recommendation, project: project, status: "pending", priority: "high")
        create(:knowledge_recommendation, project: project, status: "accepted")

        get project_knowledge_recommendations_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Knowledge Recommendations")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        get project_knowledge_recommendations_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        get project_knowledge_recommendations_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /projects/:project_id/knowledge_recommendations/:id" do
    let!(:recommendation) { create(:knowledge_recommendation, project: project, status: "pending") }

    context "when not authenticated" do
      it "redirects to the sign in page" do
        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "accept"
        }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "accept"
        }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when user has update permission" do
      before do
        sign_in user
        user.add_role(:admin, account)
      end

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
        expect(response.body).to include(%(action="remove" target="#{dom_id(recommendation)}"))
        expect(response.body).to include(%(action="replace" target="pending_recommendations_section"))
        expect(response.body).to include(%(action="replace" target="resolved_recommendations_section"))
        expect(response.body).to include(%(action="update" target="knowledge_recommendations_alert"))
      end

      it "rejects an unsupported action type" do
        patch project_knowledge_recommendation_path(project, recommendation),
          params: { action_type: "ignore" },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:bad_request)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("Unsupported action type")
        expect(response.body).to include(%(action="update" target="knowledge_recommendations_alert"))
        expect(response.body).not_to include(%(action="replace" target="knowledge_recommendations_alert"))
        expect(response.body).not_to include(%(action="remove"))
        expect(recommendation.reload.status).to eq("pending")
      end

      it "rejects updates to already-resolved recommendations" do
        recommendation.accept!

        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "accept"
        }

        expect(response).to have_http_status(:not_found)
      end

      it "requires a dismissal reason" do
        patch project_knowledge_recommendation_path(project, recommendation), params: {
          action_type: "dismiss",
          dismissal_reason: "   "
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Dismissal reason can&#39;t be blank")
        expect(recommendation.reload.status).to eq("pending")
        expect(recommendation.dismissal_reason).to be_nil
      end
    end
  end
end
