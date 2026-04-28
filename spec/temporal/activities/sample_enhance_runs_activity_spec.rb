# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::SampleEnhanceRunsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:input) { { project_id: project.id, lookback_days: 14 } }

    context "with completed enhance_issue runs" do
      let!(:issue) { create(:issue, project: project, title: "Add user authentication") }

      let!(:run_with_questions) do
        run = create(:agent_run, :completed,
          project: project, issue: issue, goal: "enhance_issue", completed_at: 1.day.ago)
        run.agent_run_logs.create!(
          log_type: "stdout",
          content: "<!-- paid:enhance-issue -->\n## Clarifying questions\n1. How does the auth flow work?\n2. Where is session config?\n## Current context\n- Some context"
        )
        create(:knowledge_usage_stat, agent_run: run, project: project,
          artifact_type: "route", artifact_count: 15, goal: "enhance_issue")
        run
      end

      let!(:run_with_context) do
        run = create(:agent_run, :completed,
          project: project, issue: issue, goal: "enhance_issue", completed_at: 2.days.ago)
        run.agent_run_logs.create!(
          log_type: "stdout",
          content: "<!-- paid:enhance-issue -->\n## Implementation context\n### Relevant files\n- app/models/user.rb"
        )
        run
      end

      it "returns sampled run data" do
        result = activity.execute(input)

        expect(result[:project_id]).to eq(project.id)
        expect(result[:runs].size).to eq(2)
      end

      it "extracts questions from clarifying runs" do
        result = activity.execute(input)

        question_run = result[:runs].find { |r| r[:agent_run_id] == run_with_questions.id }
        expect(question_run[:questions_asked]).to eq([ "How does the auth flow work?", "Where is session config?" ])
        expect(question_run[:sufficient_context]).to be false
      end

      it "marks sufficient context runs correctly" do
        result = activity.execute(input)

        context_run = result[:runs].find { |r| r[:agent_run_id] == run_with_context.id }
        expect(context_run[:questions_asked]).to be_empty
        expect(context_run[:sufficient_context]).to be true
      end

      it "includes knowledge usage data" do
        result = activity.execute(input)

        question_run = result[:runs].find { |r| r[:agent_run_id] == run_with_questions.id }
        expect(question_run[:knowledge_available]).to include("route" => 15)
      end

      it "includes artifact usage statistics" do
        result = activity.execute(input)

        expect(result[:artifact_usage]).to be_a(Hash)
      end
    end

    context "with no enhance_issue runs" do
      it "returns empty runs" do
        result = activity.execute(input)

        expect(result[:runs]).to be_empty
      end
    end

    context "with runs outside lookback window" do
      let!(:issue) { create(:issue, project: project) }

      before do
        run = create(:agent_run, :completed,
          project: project, issue: issue, goal: "enhance_issue", completed_at: 30.days.ago)
        run.agent_run_logs.create!(
          log_type: "stdout",
          content: "<!-- paid:enhance-issue -->\n## Clarifying questions\n1. Old question"
        )
      end

      it "excludes old runs" do
        result = activity.execute(input)

        expect(result[:runs]).to be_empty
      end
    end
  end
end
