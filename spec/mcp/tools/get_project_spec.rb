# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetProject do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

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
      project = create(:project, account: account)

      result = tool.call(project_id: project.id)

      expect(result[:id]).to eq(project.id)
      expect(result[:name]).to eq(project.name)
      expect(result[:repo]).to eq(project.full_name)
      expect(result[:recent_runs]).to be_an(Array)
    end

    it "includes recent agent runs" do
      project = create(:project, account: account)
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
      expect(result.dig(:lid, :planning, :planning_pr_correction_supported)).to be(false)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "reuses the authorized project lookup during perform" do
      project = create(:project, account: account)
      scope = instance_double(ActiveRecord::Relation)

      allow(tool).to receive(:policy_scope).with(Project).and_return(scope)
      expect(scope).to receive(:find).once.with(project.id).and_return(project)

      tool.call(project_id: project.id)
    end
  end
end
