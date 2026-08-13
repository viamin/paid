# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::Synthesize, :no_db do
  let(:project) { Struct.new(:id).new(123) }
  let(:session) { Struct.new(:project).new(project) }
  let(:project_version) { Object.new }
  let(:collector_run) do
    Class.new do
      def mark_completed!(count:); end
    end.new
  end
  let(:artifacts) { [ Object.new, Object.new ] }
  let(:knowledge_artifact_class) do
    Class.new do
      def self.bust_artifact_counts_cache(_project_id); end
    end
  end

  before do
    stub_const("KnowledgeArtifact", knowledge_artifact_class)
  end

  describe ".call" do
    it "busts the artifact counts cache after the transaction commits" do
      callback = nil
      service = described_class.new(session: session)

      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(service).to receive(:find_or_create_project_version!).with(project).and_return(project_version)
      allow(service).to receive(:find_or_create_collector_run!).with(project_version).and_return(collector_run)
      allow(service).to receive(:stale_prior_artifacts!).with(project, collector_run)
      allow(service).to receive(:create_artifacts!).with(project, collector_run).and_return(artifacts)
      allow(collector_run).to receive(:mark_completed!).with(count: artifacts.size)
      allow(ActiveRecord).to receive(:after_all_transactions_commit) { |&block| callback = block }
      allow(KnowledgeArtifact).to receive(:bust_artifact_counts_cache)

      result = service.call

      expect(result).to eq({ collector_run: collector_run, artifacts_count: artifacts.size })
      expect(KnowledgeArtifact).not_to have_received(:bust_artifact_counts_cache)

      callback.call

      expect(KnowledgeArtifact).to have_received(:bust_artifact_counts_cache).with(project.id)
    end

    it "does not schedule cache invalidation when the transaction rolls back" do
      service = described_class.new(session: session)

      allow(ActiveRecord::Base).to receive(:transaction).and_yield
      allow(service).to receive(:find_or_create_project_version!).with(project).and_return(project_version)
      allow(service).to receive(:find_or_create_collector_run!).with(project_version).and_return(collector_run)
      allow(service).to receive(:stale_prior_artifacts!).with(project, collector_run)
      allow(service).to receive(:create_artifacts!).with(project, collector_run).and_raise(StandardError, "boom")
      allow(KnowledgeArtifact).to receive(:bust_artifact_counts_cache)

      expect(ActiveRecord).not_to receive(:after_all_transactions_commit)
      expect {
        service.call
      }.to raise_error(StandardError, "boom")
      expect(KnowledgeArtifact).not_to have_received(:bust_artifact_counts_cache)
    end
  end
end
