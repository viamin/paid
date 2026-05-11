# frozen_string_literal: true

require "rails_helper"

RSpec.describe "StrategyReviews" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:strategy) { create(:strategy, :for_account, account: account, name: "Issue Execution") }
  let!(:active_version) do
    strategy.create_version!(
      content: { "mode" => "single" },
      provenance: { "source" => "seed" },
      promotion_state: "active",
      created_by: "seed",
      promoted_at: Time.current,
      promoted_by_user: user
    ).tap { |version| strategy.update!(current_version: version) }
  end
  let!(:pending_version) do
    strategy.create_pending_version!(
      content: { "mode" => "parallel" },
      provenance: { "source" => "evolution" },
      change_notes: "Evolved candidate",
      created_by: "evolution",
      parent_version: active_version
    )
  end

  describe "GET /strategy_reviews" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get strategy_reviews_queue_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists pending strategy versions in the user's account" do
        get strategy_reviews_queue_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Strategy Review Queue")
        expect(response.body).to include(strategy.name)
      end

      it "hides strategies from other accounts" do
        other_account = create(:account)
        other_strategy = create(:strategy, :for_account, account: other_account, name: "Secret Strategy")
        other_strategy.create_pending_version!(
          content: { "mode" => "secret" },
          provenance: { "source" => "evolution" },
          created_by: "evolution"
        )

        get strategy_reviews_queue_path

        expect(response.body).not_to include(other_strategy.name)
      end

      it "excludes global strategies that cannot be reviewed through this flow" do
        global_strategy = create(:strategy, :global, name: "Global Strategy")
        global_strategy.create_pending_version!(
          content: { "mode" => "global" },
          provenance: { "source" => "evolution" },
          created_by: "evolution"
        )

        get strategy_reviews_queue_path

        expect(response.body).not_to include(global_strategy.name)
      end
    end
  end

  describe "GET /strategies/:strategy_id/reviews" do
    before { sign_in user }

    it "lists pending versions for this strategy" do
      get strategy_reviews_path(strategy)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Pending Reviews")
      expect(response.body).to include("v#{pending_version.version}")
    end
  end

  describe "GET /strategies/:strategy_id/reviews/:id" do
    before { sign_in user }

    it "shows the review detail with a diff against the active version" do
      get strategy_review_path(strategy, pending_version)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Evolved candidate")
      expect(response.body).to include("Promotion Diff")
      expect(response.body).to include("\"parallel\"")
    end
  end

  describe "POST /strategies/:strategy_id/reviews/:id/approve" do
    before { sign_in user }

    it "approves the candidate and promotes it to current" do
      post approve_strategy_review_path(strategy, pending_version)

      expect(pending_version.reload).to be_active
      expect(pending_version.promoted_by_user).to eq(user)
      expect(strategy.reload.current_version).to eq(pending_version)
      expect(active_version.reload).to be_retired
      expect(response).to redirect_to(strategy_reviews_path(strategy))
    end

    context "when user lacks update permission" do
      let(:secondary_user) { create(:user, :viewer, account: account) }

      it "is denied" do
        sign_out user
        sign_in secondary_user

        post approve_strategy_review_path(strategy, pending_version)

        expect(pending_version.reload).to be_pending_review
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /strategies/:strategy_id/reviews/:id/reject" do
    before { sign_in user }

    it "rejects the candidate and leaves the current version unchanged" do
      post reject_strategy_review_path(strategy, pending_version)

      expect(pending_version.reload).to be_rejected
      expect(strategy.reload.current_version).to eq(active_version)
    end
  end

  describe "PATCH /strategies/:strategy_id/reviews/:id" do
    before { sign_in user }

    it "creates a new pending variant and supersedes the old one" do
      expect {
        patch strategy_review_path(strategy, pending_version), params: {
          strategy_version: {
            content: JSON.pretty_generate({ "mode" => "hybrid" }),
            change_notes: "Reviewer edit",
            reasoning: "Tighten rollout guardrails"
          }
        }
      }.to change(StrategyVersion, :count).by(1)

      new_version = strategy.reload.strategy_versions.order(:version).last
      expect(new_version).to be_pending_review
      expect(new_version.content).to eq({ "mode" => "hybrid" })
      expect(new_version.parent_version).to eq(pending_version)
      expect(pending_version.reload).to be_rejected
      expect(response).to redirect_to(strategy_review_path(strategy, new_version))
    end
  end
end
