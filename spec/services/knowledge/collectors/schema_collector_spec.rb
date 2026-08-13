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

  shared_examples "schema collection" do |schema_file:|
    let(:artifacts) { collector.collect }

    it "sets artifact_type to schema" do
      expect(artifacts).to all(include(artifact_type: "schema"))
    end

    it "sets scope_path to the detected schema file" do
      expect(artifacts).to all(include(scope_path: schema_file))
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
  end

  describe "#collect" do
    context "with db/structure.sql (SQL format)" do
      before do
        # Remove schema.rb so structure.sql is used
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
      end

      it_behaves_like "schema collection", schema_file: "db/structure.sql"

      it "parses SQL column types correctly" do
        artifacts = collector.collect
        posts = artifacts.find { |a| a[:identifier] == "posts" }

        expect(posts[:content]).to include("title (string, not null)")
        expect(posts[:content]).to include("body (text)")
        expect(posts[:content]).to include("status (string, default: 'draft')")
        expect(posts[:content]).to include("views_count (integer, not null, default: 0)")
      end

      it "stores column and index counts" do
        artifacts = collector.collect
        posts = artifacts.find { |a| a[:identifier] == "posts" }

        expect(posts[:metadata][:column_count]).to eq(8)
        expect(posts[:metadata][:index_count]).to eq(2)
        expect(posts[:metadata][:foreign_key_count]).to eq(1)
      end
    end

    context "with db/schema.rb (Ruby format)" do
      before do
        # Remove structure.sql so schema.rb is used
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(false)
      end

      it_behaves_like "schema collection", schema_file: "db/schema.rb"

      it "stores column and index counts for schema.rb" do
        artifacts = collector.collect
        posts = artifacts.find { |a| a[:identifier] == "posts" }

        expect(posts[:metadata][:column_count]).to eq(7)
        expect(posts[:metadata][:index_count]).to eq(2)
        expect(posts[:metadata][:foreign_key_count]).to eq(1)
      end
    end

    context "when schema.rb is preferred over structure.sql" do
      it "uses schema.rb when both files exist" do
        artifacts = collector.collect

        expect(artifacts).to all(include(scope_path: "db/schema.rb"))
      end
    end

    context "when neither schema file exists" do
      let(:fixture_path) { Rails.root.join("spec/fixtures/knowledge/nonexistent").to_s }

      it "raises SkipCollector" do
        expect { collector.collect }.to raise_error(
          Knowledge::SkipCollector,
          /neither db\/schema\.rb nor db\/structure\.sql found/
        )
      end
    end

    context "when table has no corresponding model file" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
      end

      it "excludes tables without model files" do
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/tag.rb").and_return(false)

        identifiers = collector.collect.map { |a| a[:identifier] }

        expect(identifiers).not_to include("tags")
        expect(identifiers).to include("users", "posts", "comments")
      end
    end

    context "with columns that have no explicit foreign key" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(false)
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

    context "with array and custom PostgreSQL column types" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(true)
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/setting.rb").and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("#{fixture_path}/db/structure.sql").and_return(<<~SQL)
          CREATE TABLE public.settings (
              id bigint NOT NULL,
              allowed_providers text[],
              search_vector tsvector,
              ip_range cidr,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );
        SQL
      end

      it "preserves array types instead of dropping the column" do
        result = collector.collect
        settings = result.find { |a| a[:identifier] == "settings" }

        expect(settings[:content]).to include("allowed_providers (text[])")
      end

      it "preserves custom PostgreSQL types instead of dropping the column" do
        result = collector.collect
        settings = result.find { |a| a[:identifier] == "settings" }

        expect(settings[:content]).to include("search_vector (tsvector)")
        expect(settings[:content]).to include("ip_range (cidr)")
      end
    end

    context "with trigram indexes containing operator classes" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(true)
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/artifact.rb").and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("#{fixture_path}/db/structure.sql").and_return(<<~SQL)
          CREATE TABLE public.artifacts (
              id bigint NOT NULL,
              identifier character varying NOT NULL,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );

          CREATE INDEX index_artifacts_on_identifier_trgm ON public.artifacts USING gin (identifier public.gin_trgm_ops);
        SQL
      end

      it "extracts only the column name, not operator classes" do
        result = collector.collect
        artifacts = result.find { |a| a[:identifier] == "artifacts" }

        expect(artifacts[:content]).to include("index_artifacts_on_identifier_trgm (identifier)")
        expect(artifacts[:content]).not_to include("gin_trgm_ops")
        expect(artifacts[:content]).not_to include("public")
      end
    end

    context "with quoted SQL index columns" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(true)
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/template.rb").and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("#{fixture_path}/db/structure.sql").and_return(<<~SQL)
          CREATE TABLE public.templates (
              id bigint NOT NULL,
              "position" bigint NOT NULL,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );

          CREATE INDEX index_templates_on_position ON public.templates USING btree ("position");
        SQL
      end

      it "normalizes quoted SQL index columns to plain column names" do
        result = collector.collect
        templates = result.find { |a| a[:identifier] == "templates" }

        expect(templates[:content]).to include("index_templates_on_position (position)")
        expect(templates[:content]).not_to include('"position"')
      end

      it "parses quoted column definitions" do
        result = collector.collect
        templates = result.find { |a| a[:identifier] == "templates" }

        expect(templates[:content]).to include("position (bigint, not null)")
      end
    end

    context "with SQL columns that have no explicit foreign key" do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{fixture_path}/db/schema.rb").and_return(false)
        allow(File).to receive(:exist?).with("#{fixture_path}/db/structure.sql").and_return(true)
        allow(File).to receive(:exist?).with("#{fixture_path}/app/models/task.rb").and_return(true)
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with("#{fixture_path}/db/structure.sql").and_return(<<~SQL)
          CREATE TABLE public.tasks (
              id bigint NOT NULL,
              title character varying,
              assignee_id bigint,
              project_id bigint,
              created_at timestamp(6) without time zone NOT NULL,
              updated_at timestamp(6) without time zone NOT NULL
          );

          ALTER TABLE ONLY public.tasks
              ADD CONSTRAINT fk_tasks_project FOREIGN KEY (project_id) REFERENCES public.projects(id);
        SQL
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
