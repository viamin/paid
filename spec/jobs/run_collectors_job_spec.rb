# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunCollectorsJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }

  describe "#perform" do
    it "delegates to Knowledge::CollectorRunner" do
      expect(Knowledge::CollectorRunner).to receive(:call).with(
        project: project,
        commit_sha: commit_sha,
        branch: "main"
      )

      described_class.new.perform(project.id, commit_sha)
    end

    it "accepts a custom branch" do
      expect(Knowledge::CollectorRunner).to receive(:call).with(
        project: project,
        commit_sha: commit_sha,
        branch: "develop"
      )

      described_class.new.perform(project.id, commit_sha, branch: "develop")
    end
  end
end
