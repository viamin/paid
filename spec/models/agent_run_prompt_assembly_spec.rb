# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-012
RSpec.describe AgentRun do
  let(:project) { create(:project, allowed_github_usernames: [ "viamin" ]) }
  let(:issue) do
    create(:issue, project: project, title: "Fix login redirect",
           github_number: 42, github_creator_login: "viamin",
           body: "Users are redirected to the wrong page.")
  end
  let(:agent_run) { create(:agent_run, project: project, issue: issue, goal: "create_pr") }

  before do
    allow(Knowledge::ContextBundle::Build).to receive(:call).and_return(
      content: "", sections: [], total_tokens: 0, queries_made: 0
    )
    allow(project).to receive(:github_token).and_return(nil)
  end

  describe "#prompt_for_issue" do
    it "returns a prompt assembled through PromptAssembly" do
      prompt = agent_run.prompt_for_issue

      expect(prompt).to include("Fix login redirect")
      expect(prompt).to include("#42")
      expect(prompt).to include("MUST pass before every commit")
    end

    it "memoizes the assembly result for provenance persistence" do
      agent_run.prompt_for_issue

      expect(agent_run.instance_variable_get(:@prompt_assembly_result)).to be_a(PromptAssembly::Result)
    end
  end

  describe "#effective_prompt provenance persistence" do
    it "persists prompt assembly provenance to external_metadata" do
      agent_run.effective_prompt

      agent_run.reload
      provenance = agent_run.external_metadata["prompt_assembly"]
      expect(provenance).to be_present
      expect(provenance["digest"]).to match(/\A[0-9a-f]{64}\z/)
      expect(provenance["sections"]).to be_an(Array)
    end

    it "records included and skipped sections in the provenance" do
      agent_run.effective_prompt

      agent_run.reload
      sections = agent_run.external_metadata["prompt_assembly"]["sections"]
      keys = sections.map { |s| s["key"] }
      expect(keys).to include("issue_task", "safety_rules")
    end
  end

  describe "#effective_prompt marketplace dedup" do
    before do
      marketplace_entry = create(:marketplace_entry, account: project.account)
      version = marketplace_entry.create_version!(
        canonical_artifact: { "content" => "Run tests first." },
        renderers: {
          "claude" => {
            "attachment_strategy" => "prompt_append",
            "provider_format" => "claude",
            "payload" => { "content" => "Run tests first." }
          }
        }
      )
      create(:agent_run_marketplace_entry,
             agent_run: agent_run,
             marketplace_entry: marketplace_entry,
             marketplace_entry_version: version,
             attachment_source: "manual",
             rendered_format: "claude",
             rendered_payload: version.renderers["claude"])
    end

    it "includes marketplace content in the effective prompt" do
      prompt = agent_run.effective_prompt

      expect(prompt).to include("Marketplace Attachments")
      expect(prompt).to include("Run tests first.")
    end

    it "does not double-inject marketplace content" do
      prompt = agent_run.effective_prompt

      occurrences = prompt.scan("Marketplace Attachments").length
      expect(occurrences).to eq(1)
    end

    it "reports marketplace as handled by the assembly" do
      agent_run.effective_prompt

      expect(agent_run.prompt_assembly_marketplace_handled?).to be true
    end
  end

  describe "#effective_prompt without marketplace" do
    it "still produces a valid prompt" do
      prompt = agent_run.effective_prompt

      expect(prompt).to include("Fix login redirect")
      expect(prompt).to include("MUST pass before every commit")
    end

    it "persists provenance" do
      agent_run.effective_prompt

      agent_run.reload
      expect(agent_run.external_metadata["prompt_assembly"]).to be_present
    end
  end
end
