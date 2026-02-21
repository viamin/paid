# frozen_string_literal: true

require "rails_helper"

RSpec.describe IndexProjectJob do
  let(:project) { create(:project) }
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  describe "#perform" do
    before do
      File.write(File.join(repo_path, "app.rb"), "def hello; end")
    end

    it "indexes the project" do
      expect {
        described_class.new.perform(project.id, repo_path)
      }.to change(CodeChunk, :count)
    end

    it "logs the indexing start and finish" do
      allow(Rails.logger).to receive(:info)

      described_class.new.perform(project.id, repo_path)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "semantic_search.index_started")
      )
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "semantic_search.index_finished")
      )
    end

    it "handles missing project gracefully" do
      allow(Rails.logger).to receive(:warn)

      expect {
        described_class.new.perform(-1, repo_path)
      }.not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "semantic_search.index_skipped")
      )
    end
  end
end
