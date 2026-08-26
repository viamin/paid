# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetProject do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }

  def lid_project
    create(
      :project,
      account: account,
      lid_mode: "full",
      lid_detection: {
        "version" => "1.3.0",
        "sources" => [ "docs/intent/" ],
        "warnings" => []
      }
    )
  end

  describe "#call" do
    it "returns project details" do
      result = tool.call(project_id: project.id)

      expect(result[:id]).to eq(project.id)
      expect(result[:name]).to eq(project.name)
      expect(result[:repo]).to eq(project.full_name)
      expect(result[:github_diagnostics]).to be_a(Hash)
      expect(result[:recent_runs]).to be_an(Array)
    end

    it "includes recent agent runs" do
      run = create(:agent_run, project: project)

      result = tool.call(project_id: project.id)

      expect(result[:recent_runs].size).to eq(1)
      expect(result[:recent_runs].first[:id]).to eq(run.id)
    end

    it "includes the external-agent LID contract" do
      project = lid_project

      result = tool.call(project_id: project.id)

      expect(result.dig(:lid, :configured)).to be(true)
      expect(result.dig(:lid, :mode)).to eq("full")
      expect(result.dig(:lid, :detection)).to include(
        "version" => "1.3.0",
        "sources" => [ "docs/intent/" ]
      )
      expect(result.dig(:lid, :workflow_contract, :implementation_prompt))
        .to include("## LID-Aware Workflow", "This repository declares Linked-Intent Development mode: `full`.")
      expect(result.dig(:lid, :planning, :trigger_goal)).to eq("lid_planning")
      expect(result.dig(:lid, :planning, :planning_pr_correction_supported)).to be(true)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "reuses the authorized project lookup during perform" do
      scope = instance_double(ActiveRecord::Relation)

      allow(tool).to receive(:policy_scope).with(Project).and_return(scope)
      expect(scope).to receive(:find).once.with(project.id).and_return(project)

      tool.call(project_id: project.id)
    end

    context "with app-backed diagnostics" do
      let(:installation) { create(:github_installation, account: account) }
      let(:fallback_token) { create(:github_token, account: account, name: "Fallback PAT") }
      let(:project) do
        create(
          :project,
          :with_github_installation,
          account: account,
          github_installation: installation,
          webhook_secret: "project-webhook-secret"
        )
      end
      let(:result) { tool.call(project_id: project.id) }

      before do
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        create(
          :issue,
          :pull_request,
          project: project,
          merge_permission_rejected_at: Time.current,
          merge_permission_rejection_reason: "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission"
        )
      end

      it "exposes sanitized GitHub diagnostics to non-operator project users" do
        expect(result.dig(:github_diagnostics, :credential_mode)).to eq("app")
        expect(result.dig(:github_diagnostics, :recent_permission_failures, 0, :code))
          .to eq("missing_workflows_permission")
      end

      it "returns only safe fallback token metadata" do
        expect(result.dig(:github_diagnostics, :pat_fallback, :token)).to eq(
          id: fallback_token.id,
          name: "Fallback PAT"
        )
      end

      it "redacts the webhook secret and token value" do
        serialized = result[:github_diagnostics].to_json

        expect(serialized).not_to include(project.webhook_secret)
        expect(serialized).not_to include(fallback_token.token)
      end
    end
  end
end
