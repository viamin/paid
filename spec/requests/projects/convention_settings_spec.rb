# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ConventionSettings" do
  include ActionView::RecordIdentifier

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/convention_settings" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_convention_settings_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        sign_in user
        user.add_role(:admin, account)
      end

      it "shows the convention settings page" do
        get project_convention_settings_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Convention Settings")
      end

      it "renders detected conventions" do
        project_version = create(:project_version, project: project)
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits" },
               evidence: { "paths" => [ ".commitlintrc" ], "signals" => [ "commitlint" ] },
               confidence: 0.9)

        get project_convention_settings_path(project)

        expect(response.body).to include("commit_style")
        expect(response.body).to include("90%")
      end

      it "renders pending recommendations" do
        create(:project_convention_recommendation, project: project, title: "Enable commit hooks")

        get project_convention_settings_path(project)

        expect(response.body).to include("Enable commit hooks")
      end

      it "renders conflict warnings" do
        project_version = create(:project_version, project: project)
        create(:project_convention_detection,
               project: project,
               project_version: project_version,
               key: "commit_style",
               value: { "type" => "conventional_commits" },
               confidence: 0.9)
        create(:project_convention_override,
               project: project,
               key: "commit_style",
               value: { "type" => "custom" },
               mode: "warn")

        get project_convention_settings_path(project)

        expect(response.body).to include("Convention conflicts detected")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        get project_convention_settings_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /projects/:project_id/convention_settings/update_override" do
    let(:project_version) { create(:project_version, project: project) }

    before do
      sign_in user
      user.add_role(:admin, account)
      create(:project_convention_detection,
             project: project,
             project_version: project_version,
             key: "commit_style",
             value: { "type" => "conventional_commits" },
             confidence: 0.9)
    end

    it "creates an override with apply mode" do
      post update_override_project_convention_settings_path(project),
           params: { key: "commit_style", mode: "apply", value: '{"type":"conventional_commits"}' },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      override = project.project_convention_overrides.find_by(key: "commit_style")
      expect(override.mode).to eq("apply")
      expect(override.enabled).to be(true)
    end

    it "creates an override with ignore mode" do
      post update_override_project_convention_settings_path(project),
           params: { key: "commit_style", mode: "ignore", value: '{}' },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      override = project.project_convention_overrides.find_by(key: "commit_style")
      expect(override.mode).to eq("ignore")
      expect(override.enabled).to be(false)
    end

    it "creates an override with warn mode" do
      post update_override_project_convention_settings_path(project),
           params: { key: "commit_style", mode: "warn", value: '{}' },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      override = project.project_convention_overrides.find_by(key: "commit_style")
      expect(override.mode).to eq("warn")
      expect(override.enabled).to be(true)
    end

    it "rejects an invalid mode" do
      post update_override_project_convention_settings_path(project),
           params: { key: "commit_style", mode: "invalid", value: '{}' },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("Unsupported mode")
    end

    it "rejects a missing key" do
      post update_override_project_convention_settings_path(project),
           params: { mode: "apply", value: '{}' },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("Key is required")
    end

    it "rejects invalid JSON value" do
      post update_override_project_convention_settings_path(project),
           params: { key: "commit_style", mode: "apply", value: "not-json" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("Value must be a JSON object")
    end
  end

  describe "PATCH /projects/:project_id/convention_settings/update_recommendation" do
    let!(:recommendation) do
      create(:project_convention_recommendation,
             project: project,
             evidence: {
               "paths" => [ ".commitlintrc.json" ],
               "signals" => [ "commitlint" ],
               "confidence" => 0.95,
               "detected_value" => { "type" => "conventional_commits", "required" => true }
             })
    end

    before do
      sign_in user
      user.add_role(:admin, account)
    end

    it "applies an apply_in_paid recommendation by creating an override" do
      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "apply" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(recommendation.reload.status).to eq("applied")
      expect(project.project_convention_overrides.find_by(key: recommendation.convention_key)).to have_attributes(
        mode: "apply",
        value: recommendation.evidence.fetch("detected_value")
      )
    end

    it "dismisses a recommendation with a reason" do
      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "dismiss", dismissal_reason: "Not relevant" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(recommendation.reload.status).to eq("dismissed")
      expect(recommendation.dismissal_reason).to eq("Not relevant")
    end

    it "rejects an unsupported action type" do
      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "ignore" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("Unsupported action type")
      expect(recommendation.reload.status).to eq("pending")
    end

    it "rejects apply for recommendations without automated backing behavior" do
      recommendation.update!(action_type: "manual_review")

      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "apply" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("cannot be applied automatically")
      expect(recommendation.reload.status).to eq("pending")
      expect(project.project_convention_overrides.find_by(key: recommendation.convention_key)).to be_nil
    end

    it "applies an open_pr recommendation by opening a repo-managed hook PR" do
      recommendation.update!(
        action_type: "open_pr",
        evidence: recommendation.evidence.merge("strategy" => open_pr_strategy)
      )
      result = open_pr_result
      allow(ProjectConventions::OpenHookGuardrailPullRequest).to receive(:call).and_return(result)

      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "apply" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Opened pull request")
      expect(response.body).to include("https://github.com/acme/widgets/pull/42")
      expect(recommendation.reload.status).to eq("applied")
      expect(ProjectConventions::OpenHookGuardrailPullRequest).to have_received(:call).with(
        project: project,
        recommendation: recommendation
      )
    end

    it "rejects updates to already-resolved recommendations" do
      recommendation.apply!(applied_by: user)

      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "apply" }

      expect(response).to have_http_status(:not_found)
    end

    it "requires a dismissal reason" do
      patch update_recommendation_project_convention_settings_path(project),
            params: { id: recommendation.id, action_type: "dismiss", dismissal_reason: "   " },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Dismissal reason can&#39;t be blank")
      expect(recommendation.reload.status).to eq("pending")
    end
  end

  describe "GET /projects/:project_id/convention_settings for manual recommendations" do
    let!(:recommendation) do
      create(:project_convention_recommendation, project: project, action_type: "manual_review", title: "Review detected release automation")
    end

    before do
      sign_in user
      user.add_role(:admin, account)
    end

    it "renders non-automated recommendations as dismiss-only" do
      get project_convention_settings_path(project)

      row = Nokogiri::HTML(response.body).at_css("tr##{dom_id(recommendation)}")
      submit_labels = row.css("input[type='submit'], button").map { |node| node["value"].presence || node.text.strip }

      expect(row.text).to include("Manual action outside Paid")
      expect(submit_labels).to contain_exactly("Dismiss")
    end
  end

  describe "GET /projects/:project_id/convention_settings for open_pr recommendations" do
    let!(:recommendation) do
      create(:project_convention_recommendation, project: project, action_type: "open_pr", title: "Install repo-managed hooks")
    end

    before do
      sign_in user
      user.add_role(:admin, account)
    end

    it "renders open_pr recommendations as applyable within Paid" do
      get project_convention_settings_path(project)

      row = Nokogiri::HTML(response.body).at_css("tr##{dom_id(recommendation)}")
      submit_labels = row.css("input[type='submit'], button").map { |node| node["value"].presence || node.text.strip }

      expect(row.text).not_to include("Manual action outside Paid")
      expect(submit_labels).to include("Apply", "Dismiss")
    end
  end

  def open_pr_strategy
    {
      "manager_type" => "husky",
      "hook_path" => ".husky/commit-msg",
      "validator_path" => ".paid/hooks/validate-commit-msg",
      "allowed_types" => %w[feat fix]
    }
  end

  def open_pr_result
    ProjectConventions::OpenHookGuardrailPullRequest::Result.new(
      pull_request_url: "https://github.com/acme/widgets/pull/42",
      already_configured: false
    )
  end
end
