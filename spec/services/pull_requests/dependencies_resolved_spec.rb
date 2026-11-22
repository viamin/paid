# frozen_string_literal: true

require "rails_helper"

RSpec.describe PullRequests::DependenciesResolved do
  let(:project) { create(:project, owner: "owner", repo: "repo") }
  let(:issue) { create(:issue, :pull_request, project: project, body: body) }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:collector) { instance_double(Automation::Signals::PullRequestCollector) }

  before do
    allow(collector).to receive(:dependency_comment_bodies).with(issue: issue).and_return([])
  end

  def call
    described_class.call(collector: collector, project: project, issue: issue, logger: logger)
  end

  def tracked_project(owner: "viamin", repo: "agent-harness")
    create(:project, account: project.account, owner:, repo:)
  end

  def resolve_external(result:)
    external_collector = instance_double(Automation::Signals::PullRequestCollector)
    allow(external_collector).to receive(:dependency_resolved?).with(number: 563).and_return(result)
    allow(Automation::Signals::ProviderContext).to receive(:for)
      .and_return(instance_double(Automation::Signals::ProviderContext))
    allow(Automation::Signals::PullRequestCollector).to receive(:new)
      .and_return(external_collector)
    external_collector
  end

  context "when the issue declares no dependencies" do
    let(:body) { "No dependencies here" }

    it "returns true without checking any dependency" do
      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(true)
    end
  end

  context "when a dependency section contains an implementation inventory" do
    let(:body) do
      <<~BODY
        ## Dependencies
        - #41

        Filed implementation tree: #42, #43, and #44.
      BODY
    end

    # @spec DEPENDENCY-DECLARATIONS-005
    it "checks only the declared list-item dependency" do
      expect(collector).to receive(:dependency_resolved?).with(number: 41).and_return(true)
      expect(collector).not_to receive(:dependency_resolved?).with(number: 42)

      expect(call).to be(true)
    end
  end

  context "when a dependency-section bullet describes the source issue's prerequisites" do
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 4981, body: body) }
    let(:body) do
      <<~BODY
        ## Rollout / dependency
        - #42
        - Draft because #4868
          depends on #4863 and #4761.

        Closes #4868
      BODY
    end

    # @spec DEPENDENCY-DECLARATIONS-005, DEPENDENCY-DECLARATIONS-009
    it "proceeds when its declared prerequisite is resolved" do
      expect(collector).to receive(:dependency_resolved?).with(number: 42).and_return(true)
      expect(collector).not_to receive(:dependency_resolved?).with(number: 4868)
      expect(collector).not_to receive(:dependency_resolved?).with(number: 4863)
      expect(collector).not_to receive(:dependency_resolved?).with(number: 4761)

      expect(call).to be(true)
    end
  end

  context "when the PR body describes #4707's comma-attributed external prerequisite" do
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 5236, body: body) }
    let(:body) do
      "This setup/save correction does not prove request-level privacy enforcement: the separate verified configuration-loss gap remains #4707, blocked by viamin/agent-harness#557."
    end

    # @spec DEPENDENCY-DECLARATIONS-005, DEPENDENCY-DECLARATIONS-009
    it "does not apply the other issue's unresolved external gate" do
      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(true)
    end
  end

  context "when a same-repo dependency is resolved" do
    let(:body) { "Depends on #41" }

    it "returns true" do
      allow(collector).to receive(:dependency_resolved?).with(number: 41).and_return(true)

      expect(call).to be(true)
    end
  end

  context "when the declaration names the current pull request" do
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 4824, body: "PR #4824 is blocked by #41") }

    it "checks the dependency" do
      expect(collector).to receive(:dependency_resolved?).with(number: 41).and_return(false)

      expect(call).to be(false)
    end
  end

  context "when a same-repo dependency is not resolved" do
    let(:body) { "Depends on #41" }

    it "returns false" do
      allow(collector).to receive(:dependency_resolved?).with(number: 41).and_return(false)

      expect(call).to be(false)
    end
  end

  context "when a dependency references another repo" do
    let(:body) { "Depends on viamin/agent-harness#563" }

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "accepts a tracked external closed issue through its provider identity" do
      tracked_project
      resolve_external(result: true)

      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(true)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "keeps tracked external open issues and closed-unmerged pull requests blocked" do
      tracked_project
      external_collector = resolve_external(result: false)

      expect(call).to be(false)
      expect(call).to be(false)
      expect(external_collector).to have_received(:dependency_resolved?).with(number: 563).twice
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "matches tracked source identities case-insensitively" do
      tracked_project(owner: "Viamin", repo: "Agent-Harness")
      resolve_external(result: true)
      issue.update!(body: "Depends on VIAMIN/AGENT-HARNESS#563")

      expect(call).to be(true)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "keeps an untracked external source blocked without using the current repository client" do
      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(false)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "does not trust an identically named project from another account" do
      create(:project, owner: "viamin", repo: "agent-harness")
      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(false)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "fails closed when the tracked source is inaccessible or transiently unavailable" do
      tracked_project
      external_collector = resolve_external(result: false)
      allow(external_collector).to receive(:dependency_resolved?).with(number: 563)
        .and_raise(GithubClient::Error, "source unavailable")

      expect(call).to be(false)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "fails closed when the tracked source has no available client" do
      source = create(
        :project,
        :with_github_installation,
        account: project.account,
        owner: "viamin",
        repo: "agent-harness"
      )
      source.github_installation.update!(revoked_at: Time.current)

      expect(call).to be(false)
    end

    # @spec DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
    it "re-verifies the tracked external source on every scan" do
      tracked_project
      external_collector = resolve_external(result: true)

      expect(call).to be(true)
      expect(call).to be(true)
      expect(external_collector).to have_received(:dependency_resolved?).with(number: 563).twice
    end
  end

  context "when the dependency check fails" do
    let(:body) { "Depends on #41" }

    it "returns false" do
      allow(collector).to receive(:dependency_resolved?).and_raise(GithubClient::Error, "transient")

      expect(call).to be(false)
    end
  end
end
