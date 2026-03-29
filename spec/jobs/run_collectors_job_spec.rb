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

      it "sets knowledge_status to ready when all collectors succeed" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [ { collector_type: "tree_sitter", status: "completed" } ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("ready")
      end

      it "sets knowledge_status to failed when any collector fails" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [
            { collector_type: "tree_sitter", status: "completed" },
            { collector_type: "dependency", status: "failed" }
          ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("failed")
      end

      it "sets knowledge_status to collecting before running" do
        project.update!(knowledge_status: "pending")
        allow(Knowledge::CollectorRunner).to receive(:call) do
          expect(project.reload.knowledge_status).to eq("collecting")
          { results: [ { collector_type: "tree_sitter", status: "completed" } ] }
        end

        described_class.new.perform(project.id, commit_sha)
      end

      it "sets knowledge_status to failed when no collectors run" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(results: [])

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("failed")
      end

      it "keeps knowledge_status as collecting when any collector is in_progress" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [
            { collector_type: "tree_sitter", status: "completed" },
            { collector_type: "dependency", status: "in_progress" }
          ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("collecting")
      end

      it "sets knowledge_status to failed and re-raises when runner raises" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_raise(RuntimeError, "container exploded")

        expect {
          described_class.new.perform(project.id, commit_sha)
        }.to raise_error(RuntimeError, "container exploded")

        expect(project.reload.knowledge_status).to eq("failed")
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
