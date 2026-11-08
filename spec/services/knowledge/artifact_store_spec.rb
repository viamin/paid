# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ArtifactStore do
  subject(:store) { described_class.new(project: project, collector_run: collector_run) }

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "test") }

  let(:artifact_data) do
    {
      artifact_type: "route",
      scope_path: "config/routes.rb",
      identifier: "GET /api/users",
      content: '{"method": "GET", "path": "/api/users"}',
      metadata: { line: 10 },
      chunks: [
        { chunk_type: "definition", content: "get '/api/users', to: 'users#index'", scope_tags: [ "api" ] }
      ]
    }
  end


  describe "#store_all" do
    it "creates an artifact with chunks" do
      count = store.store_all([ artifact_data ])

      expect(count).to eq(1)
      expect(KnowledgeArtifact.count).to eq(1)
      expect(KnowledgeChunk.count).to eq(1)

      artifact = KnowledgeArtifact.first
      expect(artifact.artifact_type).to eq("route")
      expect(artifact.content_hash).to be_present
      expect(artifact.status).to eq("active")
    end

    context "when storing identical content again (same hash)" do
      let(:new_version) { create(:project_version, project: project) }
      let(:new_run) { create(:collector_run, project_version: new_version, collector_type: "test") }

      it "reassigns the existing artifact to the new run" do
        store.store_all([ artifact_data ])
        expect(KnowledgeArtifact.count).to eq(1)

        new_store = described_class.new(project: project, collector_run: new_run)
        new_store.store_all([ artifact_data ])

        expect(KnowledgeArtifact.count).to eq(1)
        expect(KnowledgeArtifact.first.collector_run).to eq(new_run)
      end

      it "does not update an artifact already assigned to this run" do
        store.store_all([ artifact_data ])
        artifact = KnowledgeArtifact.first
        artifact.update_columns(updated_at: 1.day.ago)
        prior_updated_at = artifact.reload.updated_at

        store.store_all([ artifact_data ])

        expect(artifact.reload.updated_at).to eq(prior_updated_at)
      end
    end

    context "when two artifacts have the same content but different scope_path" do
      let(:duplicate_data) do
        artifact_data.merge(
          scope_path: "config/other_routes.rb",
          identifier: "GET /api/users (alt)"
        )
      end

      it "does not raise RecordNotUnique" do
        expect { store.store_all([ artifact_data, duplicate_data ]) }.not_to raise_error
      end

      it "stores only one artifact (content_hash is unique per run)" do
        store.store_all([ artifact_data, duplicate_data ])
        expect(KnowledgeArtifact.count).to eq(1)
      end

      # @spec KNOWLEDGE-014
      it "replays an old artifact when the current run already has its content hash" do
        old_run = create(:collector_run, project_version: create(:project_version, project:), collector_type: "test")
        described_class.new(project:, collector_run: old_run).store_all([ artifact_data ])
        store.store_all([ duplicate_data ])

        expect { store.store_all([ artifact_data ]) }.not_to raise_error
        expect(KnowledgeArtifact.where(collector_run:).count).to eq(1)
      end

      # @spec KNOWLEDGE-014
      it "revives a stale current-run hash during replay" do
        store.store_all([ duplicate_data ])
        stale = KnowledgeArtifact.find_by!(collector_run:)
        stale.update!(status: "stale")
        stale.knowledge_chunks.update_all(status: "stale")

        expect { store.store_all([ artifact_data ]) }.not_to raise_error
        expect(stale.reload.status).to eq("active")
        expect(stale.identifier).to eq(artifact_data[:identifier])
        expect(stale.knowledge_chunks.active.count).to eq(1)
      end

      # @spec KNOWLEDGE-014
      it "does not revive a deleted current-run artifact during replay" do
        store.store_all([ duplicate_data ])
        deleted = KnowledgeArtifact.find_by!(collector_run:)
        deleted.update!(status: "deleted")
        deleted.knowledge_chunks.update_all(status: "deleted")

        expect { store.store_all([ artifact_data ]) }.not_to raise_error
        expect(deleted.reload.status).to eq("deleted")
        expect(deleted.knowledge_chunks.active).to be_empty
      end

      # @spec KNOWLEDGE-014
      it "reuses a stale current-run hash when an older active row is reassigned" do
        old_run = create(:collector_run, project_version: create(:project_version, project:), collector_type: "test")
        described_class.new(project:, collector_run: old_run).store_all([ artifact_data ])
        store.store_all([ duplicate_data ])
        stale = KnowledgeArtifact.find_by!(collector_run:)
        stale.update!(status: "stale")

        expect { store.store_all([ artifact_data ]) }.not_to raise_error
        expect(stale.reload).to have_attributes(status: "active", identifier: artifact_data[:identifier])
        expect(KnowledgeArtifact.where(collector_run:).count).to eq(1)
      end
    end

    context "when content changes (different hash)" do
      let(:new_version) { create(:project_version, project: project) }
      let(:new_run) { create(:collector_run, project_version: new_version, collector_type: "test") }

      let(:updated_data) do
        artifact_data.merge(content: '{"method": "GET", "path": "/api/users", "auth": true}')
      end

      it "creates a new artifact and marks the old one stale" do
        store.store_all([ artifact_data ])
        expect(KnowledgeArtifact.active.count).to eq(1)

        new_store = described_class.new(project: project, collector_run: new_run)
        new_store.store_all([ updated_data ])

        expect(KnowledgeArtifact.count).to eq(2)
        expect(KnowledgeArtifact.active.count).to eq(1)
        expect(KnowledgeArtifact.stale.count).to eq(1)
        expect(KnowledgeArtifact.active.first.collector_run).to eq(new_run)
      end
    end

    context "when an active-key race loses after another run inserts first" do
      let(:new_version) { create(:project_version, project: project) }
      let(:new_run) { create(:collector_run, project_version: new_version, collector_type: "test") }
      let(:new_store) { described_class.new(project: project, collector_run: new_run) }
      let(:updated_data) do
        artifact_data.merge(content: '{"method":"GET","path":"/api/users","auth":true}')
      end

      it "preserves the incoming content instead of reassigning the mismatched active row" do
        store.store_all([ artifact_data ])

        conflict_raised = false
        original_create_artifact = new_store.method(:create_artifact)
        allow(new_store).to receive(:create_artifact).and_wrap_original do |_method, *args|
          if conflict_raised
            original_create_artifact.call(*args)
          else
            conflict_raised = true
            raise ActiveRecord::RecordNotUnique.new('PG::UniqueViolation: ERROR: duplicate key value violates unique constraint "idx_knowledge_artifacts_active_unique"')
          end
        end

        expect { new_store.store_all([ updated_data ]) }.not_to raise_error

        expect(KnowledgeArtifact.active.count).to eq(1)
        expect(KnowledgeArtifact.stale.count).to eq(1)
        expect(KnowledgeArtifact.active.first.collector_run).to eq(new_run)
        expect(KnowledgeArtifact.active.first.content).to eq(updated_data[:content])
      end
    end

    context "when another collector session holds the artifact lock" do
      before { allow(Rails.logger).to receive(:warn) }

      # A same-thread `connection_pool.with_connection` would reuse this
      # thread's backend, so simulate the "other process" with a raw pg
      # connection — session-scoped `pg_try_advisory_lock` only contends
      # across distinct backends.
      def with_other_session_lock(lock_key)
        db_config = ActiveRecord::Base.connection_db_config.configuration_hash
        other_session = PG.connect(
          host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
          user: db_config[:username], password: db_config[:password]
        )
        other_session.exec_params(
          described_class::TRY_ADVISORY_LOCK_SQL,
          [ described_class::LOCK_NAMESPACE, lock_key ]
        )
        yield other_session
      ensure
        other_session&.close
      end

      # @spec KNOWLEDGE-001
      it "fails the attempt after bounded lock retries instead of waiting indefinitely" do
        stub_const("Knowledge::ArtifactStore::LOCK_RETRY_DELAY_SECONDS", 0.0)
        lock_key = store.send(:advisory_lock_key, artifact_data)

        with_other_session_lock(lock_key) do
          expect { store.store_all([ artifact_data ]) }
            .to raise_error(described_class::LockUnavailable, /artifact lock/)
        end

        expect(Rails.logger).to have_received(:warn)
          .exactly(described_class::LOCK_RETRY_ATTEMPTS - 1).times
          .with(hash_including(message: "knowledge.artifact_lock_contention", project_id: project.id))
        expect(KnowledgeArtifact.count).to eq(0)
      end

      # @spec KNOWLEDGE-001
      it "waits out transient contention and stores the artifact" do
        stub_const("Knowledge::ArtifactStore::LOCK_RETRY_DELAY_SECONDS", 0.0)
        lock_key = store.send(:advisory_lock_key, artifact_data)

        with_other_session_lock(lock_key) do |other_session|
          # The other holder finishes its upsert while this store waits out
          # the first contended attempt: release its lock when the store
          # reports contention, so the next acquisition succeeds.
          allow(Rails.logger).to receive(:warn).and_wrap_original do |method, *args|
            method.call(*args)
            other_session.exec_params(described_class::ADVISORY_UNLOCK_SQL,
              [ described_class::LOCK_NAMESPACE, lock_key ])
          end

          expect { store.store_all([ artifact_data ]) }.not_to raise_error
        end

        expect(Rails.logger).to have_received(:warn).once
          .with(hash_including(message: "knowledge.artifact_lock_contention", project_id: project.id))
        expect(KnowledgeArtifact.count).to eq(1)
        expect(KnowledgeChunk.count).to eq(1)
      end
    end
  end
end
