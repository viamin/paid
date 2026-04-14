# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::PreparePrPromptActivity do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :running,
      project: project,
      source_pull_request_number: 42,
      custom_prompt: "placeholder")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:activity) { described_class.new }

  let(:pr_data) do
    OpenStruct.new(
      title: "Fix the bug",
      body: "This fixes the bug",
      head: OpenStruct.new(ref: "fix-branch", sha: "abc123"),
      base: OpenStruct.new(ref: "main")
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)

    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)

    allow(github_client).to receive_messages(check_runs_for_ref: [], review_threads: [], issue_comments: [])
  end

  describe "#execute" do
    it "stores the generated prompt in custom_prompt" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      agent_run.reload
      expect(agent_run.custom_prompt).to include("Fix the bug")
      expect(agent_run.custom_prompt).to include("#42")
    end

    it "returns prompt_length" do
      result = activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      expect(result[:prompt_length]).to be > 0
      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "passes rebase_succeeded through to the prompt builder" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: false)

      agent_run.reload
      expect(agent_run.custom_prompt).to include("Merge Conflicts")
    end

    it "omits merge conflicts section when rebase succeeded" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      agent_run.reload
      expect(agent_run.custom_prompt).not_to include("Merge Conflicts")
    end

    context "with a linked issue" do
      let(:issue) do
        create(:issue,
          project: project,
          title: "Add feature X",
          github_number: 99,
          body: "Implement feature X completely.")
      end

      let(:agent_run) do
        create(:agent_run, :running,
          project: project,
          issue: issue,
          source_pull_request_number: 42,
          custom_prompt: "placeholder")
      end

      it "includes issue requirements in the prompt" do
        activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

        agent_run.reload
        expect(agent_run.custom_prompt).to include("Issue Requirements")
        expect(agent_run.custom_prompt).to include("Add feature X")
        expect(agent_run.custom_prompt).to include("#99")
      end
    end

    context "without a linked issue" do
      let(:agent_run) do
        create(:agent_run, :running,
          project: project,
          issue: nil,
          source_pull_request_number: 42,
          custom_prompt: "placeholder")
      end

      it "omits issue requirements section" do
        activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

        agent_run.reload
        expect(agent_run.custom_prompt).not_to include("Issue Requirements")
      end
    end
  end
end
