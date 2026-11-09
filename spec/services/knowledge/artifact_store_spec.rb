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

    context "when another collector holds the artifact lock" do
      # @spec KNOWLEDGE-001
      it "fails immediately instead of waiting for the advisory lock" do
        raw_connection = instance_double(PG::Connection)
        lock_result = instance_double(PG::Result, getvalue: "f")
        connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter,
          raw_connection: raw_connection)
        allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
        expect(raw_connection).to receive(:exec_params)
          .with(described_class::TRY_ADVISORY_LOCK_SQL, [ described_class::LOCK_NAMESPACE, kind_of(Integer) ])
          .and_return(lock_result)

        expect { store.store_all([ artifact_data ]) }
          .to raise_error(described_class::LockUnavailable, /artifact lock/)
      end
    end

    context "when an artifact lock transaction ends" do
      self.use_transactional_tests = false

      after { project.account.destroy! }

      # @spec KNOWLEDGE-001
      it "releases the lock after persisting the artifact" do
        locking_store = described_class.new(project:, collector_run:)
        lock_key = Digest::SHA256
          .digest([ project.id, collector_run.collector_type, artifact_data[:artifact_type],
            artifact_data[:scope_path], artifact_data[:identifier] ].join(":"))
          .unpack("l>")
          .first

        allow(locking_store).to receive(:create_artifact).and_wrap_original do |method, *args|
          result = with_competing_database_session do |connection|
            connection.exec_params(described_class::TRY_ADVISORY_LOCK_SQL,
              [ described_class::LOCK_NAMESPACE, lock_key ]).getvalue(0, 0)
          end

          expect(result).to eq("f")
          method.call(*args)
        end

        locking_store.store_all([ artifact_data ])

        result = with_competing_database_session do |connection|
          connection.exec_params(described_class::TRY_ADVISORY_LOCK_SQL,
            [ described_class::LOCK_NAMESPACE, lock_key ]).getvalue(0, 0)
        end

        expect(result).to eq("t")
      end
    end
  end

  def with_competing_database_session
    config = ActiveRecord::Base.connection.raw_connection.conninfo_hash
    connection = PG.connect(**config.slice(:host, :port, :dbname, :user, :password))
    yield connection
  ensure
    connection&.close
  end
end
