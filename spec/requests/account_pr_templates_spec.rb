# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AccountPrTemplates" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /account_pr_templates" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get account_pr_templates_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists account-level PR templates" do
        create(:pr_template, account: account, name: "standard")
        get account_pr_templates_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /account_pr_templates" do
    let(:valid_params) do
      {
        pr_template: {
          name: "standard", pr_type: "default",
          body: "## Summary\n\n{{description}}", position: 0
        }
      }
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post account_pr_templates_path, params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates an account-level PR template" do
        expect {
          post account_pr_templates_path, params: valid_params
        }.to change(PrTemplate, :count).by(1)

        expect(response).to have_http_status(:created)
        template = PrTemplate.last
        expect(template.name).to eq("standard")
        expect(template.account).to eq(account)
        expect(template).to be_account_level
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        post account_pr_templates_path, params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /account_pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, name: "standard")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "updates the template" do
        patch account_pr_template_path(pr_template),
          params: { pr_template: { name: "updated-standard" } }

        expect(response).to have_http_status(:ok)
        expect(pr_template.reload.name).to eq("updated-standard")
      end
    end
  end

  describe "DELETE /account_pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, name: "standard")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the template" do
        expect {
          delete account_pr_template_path(pr_template)
        }.to change(PrTemplate, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
