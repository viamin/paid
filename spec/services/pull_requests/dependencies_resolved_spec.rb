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

  context "when the issue declares no dependencies" do
    let(:body) { "No dependencies here" }

    it "returns true without checking any dependency" do
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

  context "when a same-repo dependency is not resolved" do
    let(:body) { "Depends on #41" }

    it "returns false" do
      allow(collector).to receive(:dependency_resolved?).with(number: 41).and_return(false)

      expect(call).to be(false)
    end
  end

  context "when a dependency references another repo" do
    let(:body) { "Depends on other/repo#41" }

    it "returns false conservatively without checking it locally" do
      expect(collector).not_to receive(:dependency_resolved?)

      expect(call).to be(false)
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
