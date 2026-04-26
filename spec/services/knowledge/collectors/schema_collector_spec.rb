# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::SchemaCollector, :no_db do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run,
      options: { scan_path: fixture_path }
    )
  end

  let(:project) { Struct.new(:id).new(1) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }
  let(:fixture_path) { Rails.root.join("spec/fixtures/knowledge").to_s }

  describe "#collector_type" do
    it "returns schema" do
      expect(collector.collector_type).to eq("schema")
    end
  end

  describe "#collect" do
    let(:artifacts) { collector.collect }

    it "sets artifact_type to schema" do
      expect(artifacts).to all(include(artifact_type: "schema"))
    end

    it "sets scope_path to db/schema.rb" do
      expect(artifacts).to all(include(scope_path: "db/schema.rb"))
    end

    it "extracts application tables" do
      identifiers = artifacts.map { |a| a[:identifier] }

      expect(identifiers).to include("users", "posts", "comments", "tags")
    end

    it "excludes internal Rails tables" do
      identifiers = artifacts.map { |a| a[:identifier] }

      expect(identifiers).not_to include("ar_internal_metadata", "schema_migrations")
    end

    it "includes column information in content" do
      users = artifacts.find { |a| a[:identifier] == "users" }

      expect(users[:content]).to include("Table: users")
      expect(users[:content]).to include("email (string, not null)")
      expect(users[:content]).to include("admin (boolean, default: false)")
    end

    it "includes index information" do
      users = artifacts.find { |a| a[:identifier] == "users" }

      expect(users[:content]).to include("Indexes:")
      expect(users[:content]).to include("index_users_on_email (email [unique])")
    end

    it "includes composite indexes" do
      posts = artifacts.find { |a| a[:identifier] == "posts" }

      expect(posts[:content]).to include("index_posts_on_status_and_published_at (status, published_at)")
    end

    it "includes foreign key information" do
      posts = artifacts.find { |a| a[:identifier] == "posts" }

      expect(posts[:content]).to include("Foreign Keys:")
      expect(posts[:content]).to include("user_id → users")
    end

    it "infers belongs_to associations from foreign keys" do
      posts = artifacts.find { |a| a[:identifier] == "posts" }
      context_chunk = posts[:chunks].find { |c| c[:chunk_type] == "context" }

      expect(context_chunk[:content]).to include("belongs_to :user")
    end

    it "infers has_many associations from foreign keys" do
      users = artifacts.find { |a| a[:identifier] == "users" }
      context_chunk = users[:chunks].find { |c| c[:chunk_type] == "context" }

      expect(context_chunk[:content]).to include("has_many :posts")
      expect(context_chunk[:content]).to include("has_many :comments")
    end

    it "detects polymorphic associations" do
      comments = artifacts.find { |a| a[:identifier] == "comments" }
      context_chunk = comments[:chunks].find { |c| c[:chunk_type] == "context" }

      expect(context_chunk[:content]).to include("Polymorphic:")
      expect(context_chunk[:content]).to include("commentable")
    end

    it "includes model name in context chunk" do
      users = artifacts.find { |a| a[:identifier] == "users" }
      context_chunk = users[:chunks].find { |c| c[:chunk_type] == "context" }

      expect(context_chunk[:content]).to include("Model: User")
    end

    it "stores metadata about the table" do
      posts = artifacts.find { |a| a[:identifier] == "posts" }

      expect(posts[:metadata][:table_name]).to eq("posts")
      expect(posts[:metadata][:column_count]).to eq(7)
      expect(posts[:metadata][:index_count]).to eq(2)
      expect(posts[:metadata][:foreign_key_count]).to eq(1)
      expect(posts[:metadata][:has_timestamps]).to be true
    end

    it "produces two chunks per artifact" do
      artifacts.each do |artifact|
        expect(artifact[:chunks].length).to eq(2)
        expect(artifact[:chunks].map { |c| c[:chunk_type] }).to eq(%w[definition context])
      end
    end

    it "produces idempotent results" do
      first_run = collector.collect
      second_run = collector.collect

      expect(first_run).to eq(second_run)
    end

    context "when db/schema.rb does not exist" do
      let(:fixture_path) { Rails.root.join("spec/fixtures/knowledge/nonexistent").to_s }

      it "raises SkipCollector" do
        expect { collector.collect }.to raise_error(Knowledge::SkipCollector, /schema.rb not found/)
      end
    end

    context "when table has no corresponding model file" do
      it "excludes tables without model files" do
        # The tags table has a model file, but if we remove it the table should be excluded
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/tag.rb").and_return(false)

        identifiers = collector.collect.map { |a| a[:identifier] }

        expect(identifiers).not_to include("tags")
        expect(identifiers).to include("users", "posts", "comments")
      end
    end

    context "with columns that have no explicit foreign key" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(true)
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/task.rb").and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("#{fixture_path}/db/schema.rb").and_return(<<~SCHEMA)
          ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
            create_table "tasks", force: :cascade do |t|
              t.string "title"
              t.bigint "assignee_id"
              t.bigint "project_id"
              t.datetime "created_at", null: false
              t.datetime "updated_at", null: false
            end

            add_foreign_key "tasks", "projects"
          end
        SCHEMA
      end

      it "infers belongs_to from column naming when no FK exists" do
        result = collector.collect
        tasks = result.find { |a| a[:identifier] == "tasks" }
        context_chunk = tasks[:chunks].find { |c| c[:chunk_type] == "context" }

        expect(context_chunk[:content]).to include("belongs_to :project")
        expect(context_chunk[:content]).to include("belongs_to :assignee (inferred)")
      end
    end
  end
end
