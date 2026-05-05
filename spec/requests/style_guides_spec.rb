# frozen_string_literal: true

require "rails_helper"

RSpec.describe "StyleGuides" do
  let(:account) { create(:account) }

  describe "GET /style_guides" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get style_guides_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as an account owner" do
      let(:user) { create(:user, :owner, account: account) }

      before do
        sign_in user
        create(:style_guide, :global, name: "Global Guide")
        create(:style_guide, :for_account, account: account, name: "Team Guide")
        project = create(:project, account: account, created_by: user)
        create(:style_guide, :for_project, project: project, account: account, name: "Project Guide")
        create(:style_guide, :for_account, name: "Other Account Guide")
      end

      it "renders successfully and shows guides in scope" do
        get style_guides_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Style Guides")
        expect(response.body).to include("Global Guide")
        expect(response.body).to include("Team Guide")
        expect(response.body).to include("Project Guide")
        expect(response.body).not_to include("Other Account Guide")
      end

      it "shows create and extract actions" do
        get style_guides_path

        expect(response.body).to include("New Style Guide")
        expect(response.body).to include("Extract from Code")
      end
    end

    context "when signed in as an account member" do
      let(:user) { create(:user, :member, account: account) }

      before do
        sign_in user
        create(:style_guide, :for_account, account: account, name: "Team Guide")
      end

      it "renders successfully without management actions" do
        get style_guides_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Style Guides")
        expect(response.body).to include("Team Guide")
        expect(response.body).not_to include("New Style Guide")
        expect(response.body).not_to include("Extract from Code")
      end
    end
  end
end
