# frozen_string_literal: true

require "rails_helper"

RSpec.describe "UserPrTemplates" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /user_pr_templates" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get user_pr_templates_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists user-level PR templates" do
        create(:pr_template, account: account, user: user, name: "my-template")
        get user_pr_templates_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /user_pr_templates" do
    let(:valid_params) do
      {
        pr_template: {
          name: "my-template", pr_type: "default",
          body: "## Summary\n\n{{description}}", position: 0
        }
      }
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a user-level PR template" do
        expect {
          post user_pr_templates_path, params: valid_params
        }.to change(PrTemplate, :count).by(1)

        expect(response).to have_http_status(:created)
        template = PrTemplate.last
        expect(template.name).to eq("my-template")
        expect(template.user).to eq(user)
        expect(template).to be_user_level
      end
    end
  end

  describe "PATCH /user_pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, user: user, name: "my-template")
    end

    context "when authenticated" do
      before { sign_in user }

      it "updates the template" do
        patch user_pr_template_path(pr_template),
          params: { pr_template: { name: "updated-template" } }

        expect(response).to have_http_status(:ok)
        expect(pr_template.reload.name).to eq("updated-template")
      end
    end
  end

  describe "DELETE /user_pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, user: user, name: "my-template")
    end

    context "when authenticated" do
      before { sign_in user }

      it "destroys the template" do
        expect {
          delete user_pr_template_path(pr_template)
        }.to change(PrTemplate, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
