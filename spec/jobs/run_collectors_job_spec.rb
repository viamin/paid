# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunCollectorsJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }

  describe "#perform" do
    context "when Docker is unavailable" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
      end

      it "delegates to Knowledge::CollectorRunner" do
        expect(Knowledge::CollectorRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha)
      end

      it "accepts a custom branch" do
        expect(Knowledge::CollectorRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "develop",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha, branch: "develop")
      end
    end

    context "when Docker is available" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(true)
      end

      it "delegates to Knowledge::ContainerizedRunner" do
        expect(Knowledge::ContainerizedRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha)
      end
    end
  end
end
