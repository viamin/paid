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
  let(:prompt) do
    Prompt.find_by(slug: Prompts::BuildForPr::PROMPT_SLUG)&.destroy!
    create(:prompt, :global, slug: Prompts::BuildForPr::PROMPT_SLUG).tap do |record|
      record.create_version!(
        template: "Priority order:\n{{priority_list}}\n# Instructions",
        variables: [
          { "name" => "priority_list", "required" => true, "description" => "Priority list" }
        ]
      )
    end
  end

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

    allow(github_client).to receive_messages(check_runs_for_ref: [], review_threads: [], recent_issue_comments: [])
  end

  describe "#execute" do
    before { prompt }

    it "stores the generated prompt in custom_prompt" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      agent_run.reload
      expect(agent_run.custom_prompt).to include("Fix the bug")
      expect(agent_run.custom_prompt).to include("#42")
    end

    it "stores the resolved prompt version on the agent run" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      expect(agent_run.reload.prompt_version).to eq(prompt.current_version)
    end

    it "renders the stored prompt from the same resolved prompt version" do
      pinned_version = prompt.create_version!(
        template: "Pinned shell {{priority_list}}",
        variables: [
          { "name" => "priority_list", "required" => true, "description" => "Priority list" }
        ]
      )
      prompt.create_version!(
        template: "New current shell",
        variables: []
      )

      allow(Prompts::Resolve).to receive(:call)
        .with(slug: Prompts::BuildForPr::PROMPT_SLUG, project: project)
        .and_return(pinned_version)

      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      agent_run.reload
      expect(agent_run.prompt_version).to eq(pinned_version)
      expect(agent_run.custom_prompt).to include("Pinned shell")
      expect(agent_run.custom_prompt).not_to include("New current shell")
    end

    it "returns prompt_length" do
      result = activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      expect(result[:prompt_length]).to be > 0
      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:includes_review_threads]).to be(false)
      expect(result[:review_thread_ids]).to eq([])
      expect(result[:prompt_version_id]).to eq(prompt.current_version.id)
    end

    it "records service environment prompt blocks on the prepare_pr_prompt phase" do
      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      phase = agent_run.reload.agent_run_phases.find_by!(phase_key: "prepare_pr_prompt")

      expect(phase.metadata["service_environment_prompt_blocks"]).to eq(
        Prompts::BuildForPr.service_environment_section_render_for(
          project: project,
          include_setup_instruction: false
        ).prompt_blocks.map(&:deep_stringify_keys)
      )
    end

    it "passes explicit focus through to the prompt builder" do
      allow(github_client).to receive(:check_runs_for_ref)
        .with(project.full_name, "abc123")
        .and_return([
          { id: 1, name: "rspec", conclusion: "failure", output_text: "failed" }
        ])
      allow(github_client).to receive(:check_run_log).and_return("")
      allow(github_client).to receive(:review_threads)
        .with(project.full_name, 42)
        .and_return([
          { id: "thread_1", is_resolved: false, comments: [ { body: "Needs a fix", path: "app/models/user.rb", line: 42, author: "reviewer" } ] }
        ])

      result = activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true, focus: "ci_fix")

      expect(agent_run.reload.custom_prompt).to include("CI Status: FAILING")
      expect(agent_run.custom_prompt).not_to include("Code Review Comments")
      expect(result[:includes_review_threads]).to be(false)
      expect(result[:review_thread_ids]).to eq([])
    end

    it "uses the agent run focus when input focus is not provided" do
      agent_run.update!(focus: "ci_fix")
      allow(github_client).to receive(:check_runs_for_ref)
        .with(project.full_name, "abc123")
        .and_return([
          { id: 1, name: "rspec", conclusion: "failure", output_text: "failed" }
        ])
      allow(github_client).to receive(:check_run_log).and_return("")
      allow(github_client).to receive(:review_threads)
        .with(project.full_name, 42)
        .and_return([
          { id: "thread_1", is_resolved: false, comments: [ { body: "Needs a fix", path: "app/models/user.rb", line: 42, author: "reviewer" } ] }
        ])

      activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

      expect(agent_run.reload.custom_prompt).to include("CI Status: FAILING")
      expect(agent_run.custom_prompt).not_to include("Code Review Comments")
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

    context "when unresolved review threads are present" do
      before do
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([
            { id: "thread_1", is_resolved: false, comments: [ { body: "Needs a fix", path: "app/models/user.rb", line: 42, author: "reviewer" } ] }
          ])
      end

      it "reports that the generated prompt included review threads" do
        result = activity.execute(agent_run_id: agent_run.id, rebase_succeeded: true)

        expect(result[:includes_review_threads]).to be(true)
        expect(result[:review_thread_ids]).to eq([ "thread_1" ])
        expect(agent_run.reload.custom_prompt).to include("Code Review Comments")
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
