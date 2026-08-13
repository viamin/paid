# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ParseMultiIssuePlanActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt,
      project: project, goal: "create_issue", custom_prompt: "Decompose feature")
  end

  before do
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)
  end

  describe "#execute" do
    it "returns nil plan when agent output has no multi-issue markers" do
      agent_run.log!("stdout", "# Simple Issue\n\nJust a regular issue body.")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "returns nil when no agent output exists" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    context "with a valid multi-issue plan" do
      before do
        agent_run.log!("stdout", <<~OUTPUT)
          <!-- parent-issue: 451 -->
          <!-- multi-issue-plan-start -->
          [
            {"title": "Add database migration", "body": "Create users table", "dependencies": []},
            {"title": "Add User model", "body": "Create ActiveRecord model", "dependencies": [0]},
            {"title": "Add API endpoint", "body": "Create controller action", "dependencies": [1]}
          ]
          <!-- multi-issue-plan-end -->
        OUTPUT
      end

      it "extracts tasks with titles and dependencies" do
        result = activity.execute(agent_run_id: agent_run.id)

        plan = result[:plan]
        expect(plan).not_to be_nil
        expect(plan[:tasks].size).to eq(3)
        expect(plan[:tasks][0][:title]).to eq("Add database migration")
        expect(plan[:tasks][0][:dependencies]).to eq([])
        expect(plan[:tasks][1][:dependencies]).to eq([ 0 ])
        expect(plan[:tasks][2][:dependencies]).to eq([ 1 ])
      end

      it "extracts the parent issue number" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:plan][:parent_issue_number]).to eq(451)
      end
    end

    it "works without parent issue reference" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [
          {"title": "Task A", "body": "Do A", "dependencies": []},
          {"title": "Task B", "body": "Do B", "dependencies": [0]}
        ]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      plan = result[:plan]
      expect(plan).not_to be_nil
      expect(plan[:parent_issue_number]).to be_nil
      expect(plan[:tasks].size).to eq(2)
    end

    it "defaults parent_issue_number to source issue when no marker present" do
      issue = create(:issue, project: project, github_number: 99)
      agent_run.update!(issue: issue)

      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [
          {"title": "Task A", "body": "Do A", "dependencies": []},
          {"title": "Task B", "body": "Do B", "dependencies": [0]}
        ]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan][:parent_issue_number]).to eq(99)
    end

    it "does not override explicit parent-issue marker with source issue" do
      issue = create(:issue, project: project, github_number: 99)
      agent_run.update!(issue: issue)

      agent_run.log!("stdout", <<~OUTPUT)
        <!-- parent-issue: 451 -->
        <!-- multi-issue-plan-start -->
        [{"title": "Task A", "body": "Do A", "dependencies": []}]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan][:parent_issue_number]).to eq(451)
    end

    it "truncates titles longer than 255 characters" do
      long_title = "A" * 500
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [{"title": "#{long_title}", "body": "body", "dependencies": []}]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan][:tasks][0][:title].length).to be <= 255
    end

    it "filters out invalid dependency indices" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [
          {"title": "Task A", "body": "Do A", "dependencies": [-1, 5, 99]},
          {"title": "Task B", "body": "Do B", "dependencies": [0]}
        ]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan][:tasks][0][:dependencies]).to eq([])
      expect(result[:plan][:tasks][1][:dependencies]).to eq([ 0 ])
    end

    it "limits to MAX_ISSUES tasks" do
      tasks = (1..25).map { |i| %({"title": "Task #{i}", "body": "body", "dependencies": []}) }
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [#{tasks.join(",")}]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan][:tasks].size).to eq(20)
    end

    it "returns nil for invalid JSON" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        not valid json
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "returns nil for empty task array" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        []
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "returns nil when a task has a blank title" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [{"title": "", "body": "body", "dependencies": []}]
        <!-- multi-issue-plan-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "logs when a multi-issue plan is detected" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- multi-issue-plan-start -->
        [{"title": "Task A", "body": "body", "dependencies": []}]
        <!-- multi-issue-plan-end -->
      OUTPUT

      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.where(log_type: "system").last
      expect(log.content).to include("multi-issue plan")
      expect(log.content).to include("1 issues")
    end
  end
end
