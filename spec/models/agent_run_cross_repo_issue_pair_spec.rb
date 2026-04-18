# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, "#cross_repo_issue_pair?" do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt,
      project: project, goal: "create_issue", custom_prompt: "Create issue pair",
      cross_repo_issues: cross_repo_issues)
  end

  describe "#upstream_issues" do
    context "with a cross-repo issue pair" do
      let(:cross_repo_issues) do
        [
          { "repo" => "viamin/agent-harness", "issue_number" => 5, "issue_url" => "https://github.com/viamin/agent-harness/issues/5", "role" => "upstream" },
          { "repo" => "viamin/paid", "issue_number" => 42, "issue_url" => "https://github.com/viamin/paid/issues/42", "role" => "downstream" }
        ]
      end

      it "returns only upstream issues" do
        expect(agent_run.upstream_issues).to eq([ cross_repo_issues.first ])
      end
    end

    context "with no cross-repo issues" do
      let(:cross_repo_issues) { [] }

      it "returns empty array" do
        expect(agent_run.upstream_issues).to eq([])
      end
    end
  end

  describe "#downstream_issues" do
    context "with a cross-repo issue pair" do
      let(:cross_repo_issues) do
        [
          { "repo" => "viamin/agent-harness", "issue_number" => 5, "issue_url" => "https://github.com/viamin/agent-harness/issues/5", "role" => "upstream" },
          { "repo" => "viamin/paid", "issue_number" => 42, "issue_url" => "https://github.com/viamin/paid/issues/42", "role" => "downstream" }
        ]
      end

      it "returns only downstream issues" do
        expect(agent_run.downstream_issues).to eq([ cross_repo_issues.last ])
      end
    end
  end

  describe "#cross_repo_issue_pair?" do
    context "with both upstream and downstream issues" do
      let(:cross_repo_issues) do
        [
          { "repo" => "viamin/agent-harness", "issue_number" => 5, "issue_url" => "https://github.com/viamin/agent-harness/issues/5", "role" => "upstream" },
          { "repo" => "viamin/paid", "issue_number" => 42, "issue_url" => "https://github.com/viamin/paid/issues/42", "role" => "downstream" }
        ]
      end

      it "returns true" do
        expect(agent_run.cross_repo_issue_pair?).to be true
      end
    end

    context "with only upstream issues" do
      let(:cross_repo_issues) do
        [ { "repo" => "viamin/agent-harness", "issue_number" => 5, "issue_url" => "https://github.com/viamin/agent-harness/issues/5", "role" => "upstream" } ]
      end

      it "returns false" do
        expect(agent_run.cross_repo_issue_pair?).to be false
      end
    end

    context "with empty cross_repo_issues" do
      let(:cross_repo_issues) { [] }

      it "returns false" do
        expect(agent_run.cross_repo_issue_pair?).to be false
      end
    end

    context "with nil cross_repo_issues" do
      let(:cross_repo_issues) { nil }

      it "returns false" do
        agent_run.update_column(:cross_repo_issues, nil)
        expect(agent_run.cross_repo_issue_pair?).to be false
      end
    end
  end
end
