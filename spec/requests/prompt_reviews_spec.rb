# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PromptReviews" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:prompt) { create(:prompt, :for_account, :requires_review, :with_version, account: account) }
  let!(:pending_version) do
    prompt.create_pending_version!(template: "Proposed variant {{title}}", change_notes: "Evolved")
  end

  describe "GET /prompt_reviews" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get prompt_reviews_queue_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists pending prompt versions in the user's account" do
        get prompt_reviews_queue_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Prompt Review Queue")
        expect(response.body).to include(prompt.name)
      end

      it "hides prompts from other accounts" do
        other_account = create(:account)
        other_prompt = create(:prompt, :for_account, :requires_review, :with_version, account: other_account)
        other_prompt.create_pending_version!(template: "Secret", change_notes: "Other")

        get prompt_reviews_queue_path
        expect(response.body).not_to include(other_prompt.name)
      end
    end
  end

  describe "GET /prompts/:prompt_id/reviews" do
    before { sign_in user }

    it "lists pending versions for this prompt" do
      get prompt_reviews_path(prompt)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Pending Reviews")
      expect(response.body).to include("v#{pending_version.version}")
    end
  end

  describe "GET /prompts/:prompt_id/reviews/:id" do
    before { sign_in user }

    it "shows the review detail with diff vs parent" do
      get prompt_review_path(prompt, pending_version)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Proposed variant")
      expect(response.body).to include("Template Diff")
      expect(response.body).to include("Quality Metrics")
    end
  end

  describe "POST /prompts/:prompt_id/reviews/:id/approve" do
    before { sign_in user }

    it "approves the version and sets it as current" do
      post approve_prompt_review_path(prompt, pending_version),
        params: { prompt_version: { review_notes: "LGTM" } }

      expect(pending_version.reload).to be_approved
      expect(prompt.reload.current_version).to eq(pending_version)
      expect(response).to redirect_to(prompt_path(prompt))
    end

    context "when user lacks update permission" do
      let(:secondary_user) { create(:user, :viewer, account: account) }

      it "is denied" do
        sign_out user
        sign_in secondary_user

        post approve_prompt_review_path(prompt, pending_version)
        expect(pending_version.reload).not_to be_approved
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /prompts/:prompt_id/reviews/:id/reject" do
    before { sign_in user }

    it "rejects the version with notes" do
      post reject_prompt_review_path(prompt, pending_version),
        params: { prompt_version: { review_notes: "Safety regression" } }

      expect(pending_version.reload).to be_rejected
      expect(pending_version.review_notes).to eq("Safety regression")
    end

    it "redirects back with an alert when notes are missing" do
      post reject_prompt_review_path(prompt, pending_version),
        params: { prompt_version: { review_notes: "" } }

      expect(pending_version.reload).to be_pending_review
      expect(flash[:alert]).to be_present
    end
  end

  describe "PATCH /prompts/:prompt_id/reviews/:id" do
    before { sign_in user }

    it "creates a new pending variant and supersedes the old one" do
      expect {
        patch prompt_review_path(prompt, pending_version),
          params: { prompt_version: { template: "Refined {{title}}", change_notes: "Reviewer edit" } }
      }.to change(PromptVersion, :count).by(1)

      new_version = prompt.reload.prompt_versions.order(:version).last
      expect(new_version).to be_pending_review
      expect(new_version.template).to eq("Refined {{title}}")
      expect(pending_version.reload).to be_rejected
      expect(response).to redirect_to(prompt_review_path(prompt, new_version))
    end
  end
end
