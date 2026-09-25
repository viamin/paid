# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::TriggerAgentRun do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe ".write_operation?" do
    it "returns true" do
      expect(described_class.write_operation?).to be(true)
    end
  end

  describe ".input_schema" do
    it "requires goal=lid_planning alongside plan_docs so clients get the real contract at validation time" do
      plan_docs_branch = described_class.input_schema[:anyOf].find do |branch|
        branch[:required]&.include?("plan_docs")
      end

      expect(plan_docs_branch[:required]).to include("goal")
      expect(plan_docs_branch[:properties][:goal][:const]).to eq("lid_planning")
    end
  end

  describe "#call" do
    let(:project) { create(:project, account: account) }
    let(:issue) { create(:issue, project: project) }

    it "creates an agent run when confirmed" do
      result = tool.call(project_id: project.id, issue_id: issue.id, confirmed: true)

      expect(result[:status]).to eq("queued")
      expect(result[:goal]).to eq("create_pr")
      expect(result[:issue_id]).to eq(issue.id)

      run = AgentRun.find(result[:id])
      expect(run.agent_type).to be_present
    end

    it "enqueues ProcessRunQueueJob" do
      expect {
        tool.call(project_id: project.id, issue_id: issue.id, confirmed: true)
      }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "raises when not confirmed" do
      expect {
        tool.call(project_id: project.id, issue_id: issue.id, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    # @spec CHAT-TOOL-CONFIRMATION-003
    it "raises an argument error when project_id is missing" do
      expect {
        tool.call(confirmed: true)
      }.to raise_error(ArgumentError, "Missing required argument: project_id")
    end

    it "raises for project in another account" do
      other_project = create(:project)
      other_issue = create(:issue, project: other_project)

      expect {
        tool.call(project_id: other_project.id, issue_id: other_issue.id, confirmed: true)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "with viewer role" do
      it "raises authorization error for non-member user" do
        # Ensure project exists first so its factory creates the first user (auto-owner)
        project
        viewer = create(:user, account: account)
        viewer_tool = described_class.new(user: viewer, session: session)

        expect {
          viewer_tool.call(project_id: project.id, issue_id: issue.id, confirmed: true)
        }.to raise_error(Pundit::NotAuthorizedError)
      end
    end

    it "returns an invalid params error when an active run already exists" do
      allow(AgentRun).to receive(:create!)
        .and_raise(ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue"))

      expect {
        tool.call(project_id: project.id, issue_id: issue.id, confirmed: true)
      }.to raise_error(ArgumentError, "An agent run is already queued or in progress for this issue")
    end

    context "with review depth snapshotting" do
      before { allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true) }

      it "snapshots the project's effective review depth preset onto the run" do # @spec REVIEW-DEPTH-006
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => { "paid_agent" => { "enabled" => true, "review_depth" => "focused" } }
        })

        result = tool.call(
          project_id: project.id,
          goal: "create_issue",
          custom_prompt: "Investigate flaky review depth coverage.",
          confirmed: true
        )

        expect(AgentRun.find(result[:id]).review_depth_snapshot).to eq("focused")
      end

      it "snapshots the balanced default for unconfigured projects" do # @spec REVIEW-DEPTH-006
        result = tool.call(
          project_id: project.id,
          goal: "create_issue",
          custom_prompt: "Investigate flaky review depth coverage.",
          confirmed: true
        )

        expect(AgentRun.find(result[:id]).review_depth_snapshot).to eq("balanced")
      end
    end

    context "with goal create_issue and no issue_id" do
      it "creates an agent run from custom_prompt alone" do
        result = tool.call(
          project_id: project.id,
          goal: "create_issue",
          custom_prompt: "Fix the invisible chat popup overlay blocking clicks.",
          confirmed: true
        )

        expect(result[:status]).to eq("queued")
        expect(result[:issue_id]).to be_nil

        run = AgentRun.find(result[:id])
        expect(run.issue_id).to be_nil
        expect(run.custom_prompt).to eq("Fix the invisible chat popup overlay blocking clicks.")
      end

      it "raises when neither issue_id nor custom_prompt is given" do
        expect {
          tool.call(project_id: project.id, goal: "create_issue", confirmed: true)
        }.to raise_error(ArgumentError, "issue_id or custom_prompt is required")
      end
    end

    context "with goal create_feature" do
      # @spec FEATURE-CREATION-007
      let(:problem_framing) do
        {
          "observations" => [ "Reviewers wait for assignment context" ],
          "evidence_references" => [ "Support ticket #123" ],
          "affected_stakeholders" => [ "Reviewers", "Authors" ],
          "selected_framing" => "Reduce avoidable reviewer waiting time",
          "selected_framing_rationale" => "Waiting time dominates the review cost",
          "selected_framing_confirmed" => false,
          "alternative_framings" => [ "Increase reviewer capacity" ],
          "unresolved_assumptions" => [ "Notifications reach active reviewers" ],
          "desired_outcome" => "Review waiting time decreases",
          "reconsideration_conditions" => [ "Waiting time does not improve after adoption" ]
        }
      end

      it "stores an enriched chat brief in feature metadata instead of custom_prompt" do
        brief = {
          "title" => "Notify reviewers",
          "problem" => "Reviews wait too long",
          "problem_framing" => problem_framing
        }

        result = tool.call(
          project_id: project.id,
          goal: "create_feature",
          custom_prompt: brief.to_json,
          confirmed: true
        )

        run = AgentRun.find(result[:id])
        expect(run.custom_prompt).to be_nil
        expect(run.external_metadata["feature_brief"]).to eq(brief)
        expect(run.send(:prompt_for_goal)).to include(
          "Support ticket #123",
          "Reduce avoidable reviewer waiting time",
          "Notifications reach active reviewers",
          "Waiting time does not improve after adoption"
        )
      end

      it "renders an unconfirmed framing as proposed, never user-confirmed" do
        result = tool.call(
          project_id: project.id,
          goal: "create_feature",
          custom_prompt: { "title" => "Notify reviewers", "problem_framing" => problem_framing }.to_json,
          confirmed: true
        )

        prompt = AgentRun.find(result[:id]).send(:prompt_for_goal)
        expect(prompt).to include("Proposed selected framing (not user-confirmed")
        expect(prompt).not_to include("User-confirmed selected framing")
      end

      it "renders a framing user-confirmed only when the brief asserts the confirmation flag" do
        brief = {
          "title" => "Notify reviewers",
          "problem_framing" => problem_framing.merge("selected_framing_confirmed" => true)
        }

        result = tool.call(
          project_id: project.id,
          goal: "create_feature",
          custom_prompt: brief.to_json,
          confirmed: true
        )

        prompt = AgentRun.find(result[:id]).send(:prompt_for_goal)
        expect(prompt).to include("User-confirmed selected framing:")
        expect(prompt).not_to include("Proposed selected framing")
      end

      it "keeps an ordinary text brief on the existing create-feature path" do
        result = tool.call(
          project_id: project.id,
          goal: "create_feature",
          custom_prompt: "Add notifications so reviews happen faster",
          confirmed: true
        )

        run = AgentRun.find(result[:id])
        expect(run.custom_prompt).to be_nil
        expect(run.external_metadata["feature_brief"]).to include(
          "title" => "Add notifications so reviews happen faster",
          "problem" => "Add notifications so reviews happen faster"
        )
        expect(run.external_metadata["feature_brief"]).not_to have_key("problem_framing")
      end
    end

    context "with plan_docs for lid_planning" do
      it "stores named plan docs in external_metadata" do
        result = tool.call(
          project_id: project.id,
          goal: "lid_planning",
          custom_prompt: "Plan the auth module.",
          plan_docs: [ { "name" => "docs/rdrs/RDR-051.md" } ],
          confirmed: true
        )

        run = AgentRun.find(result[:id])
        expect(run.external_metadata["plan_docs"]).to eq(
          [ { "name" => "docs/rdrs/RDR-051.md" } ]
        )
      end

      it "filters out entries without a name" do
        result = tool.call(
          project_id: project.id,
          goal: "lid_planning",
          custom_prompt: "Plan the auth module.",
          plan_docs: [ { "name" => "docs/rdrs/RDR-051.md" }, { "path" => "no-name" } ],
          confirmed: true
        )

        run = AgentRun.find(result[:id])
        expect(run.external_metadata["plan_docs"]).to eq(
          [ { "name" => "docs/rdrs/RDR-051.md" } ]
        )
      end

      it "creates a run from plan_docs alone with no issue_id or custom_prompt" do
        result = tool.call(
          project_id: project.id,
          goal: "lid_planning",
          plan_docs: [ { "name" => "docs/rdrs/RDR-051.md" } ],
          confirmed: true
        )

        expect(result[:status]).to eq("queued")
        expect(result[:issue_id]).to be_nil

        run = AgentRun.find(result[:id])
        expect(run.issue_id).to be_nil
        expect(run.custom_prompt).to be_nil
        expect(run.external_metadata["plan_docs"]).to eq(
          [ { "name" => "docs/rdrs/RDR-051.md" } ]
        )
      end

      it "raises when lid_planning has no plan_docs, issue_id, or custom_prompt" do
        expect {
          tool.call(project_id: project.id, goal: "lid_planning", confirmed: true)
        }.to raise_error(ArgumentError, "issue_id or custom_prompt is required")
      end

      it "raises when plan_docs are given for a non-lid_planning goal without issue_id or custom_prompt" do
        expect {
          tool.call(
            project_id: project.id,
            goal: "create_pr",
            plan_docs: [ { "name" => "docs/rdrs/RDR-051.md" } ],
            confirmed: true
          )
        }.to raise_error(ArgumentError, "issue_id or custom_prompt is required")
      end
    end
  end
end
