# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Knowledge::ContextBundle::Build do
  let(:project) { create(:project) }
  let(:issue) do
    OpenStruct.new(
      title: "Fix user login",
      github_number: 42,
      body: "Users can't log in"
    )
  end
  let(:collector_run) { create(:collector_run, :completed, project_version: create(:project_version, project: project)) }

  describe ".call" do
    context "when knowledge base is empty" do
      it "returns an empty result" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:content]).to eq("")
        expect(result[:sections]).to be_empty
        expect(result[:total_tokens]).to eq(0)
        expect(result[:queries_made]).to eq(0)
      end
    end

    context "with route artifacts" do
      before do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "route",
          identifier: "POST /api/users → UsersController#create",
          content: "POST /api/users",
          status: "active")
      end

      it "includes a routes section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:routes)
        expect(result[:content]).to include("Relevant Routes")
        expect(result[:content]).to include("POST /api/users → UsersController#create")
      end
    end

    context "with symbol artifacts" do
      before do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "symbol",
          scope_path: "app/models/user.rb",
          identifier: "User",
          content: "User model with Devise authentication",
          status: "active")
      end

      it "includes a symbols section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:symbols)
        expect(result[:content]).to include("Related Code")
        expect(result[:content]).to include("app/models/user.rb")
        expect(result[:content]).to include("User")
      end
    end

    context "with churn hotspot artifacts" do
      before do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "churn_hotspot",
          scope_path: "app/models/user.rb",
          identifier: "app/models/user.rb",
          content: "high churn file",
          metadata: { "revisions" => 47 },
          status: "active")
      end

      it "includes a hotspots section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:hotspots)
        expect(result[:content]).to include("Hotspot Warning")
        expect(result[:content]).to include("47 revisions")
        expect(result[:content]).to include("careful review")
      end
    end

    context "with decision records" do
      before do
        create(:decision_record,
          project: project,
          title: "Use Devise for authentication",
          status: "active")
      end

      it "includes a decisions section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:decisions)
        expect(result[:content]).to include("Recent Decisions")
        expect(result[:content]).to include("Use Devise for authentication")
        expect(result[:content]).to include("active")
      end
    end

    context "with language stat artifacts" do
      before do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "language_stat",
          identifier: "Ruby",
          content: "Ruby language stats",
          metadata: { "code" => 15_234, "files" => 187 },
          status: "active")
      end

      it "includes a stats section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:stats)
        expect(result[:content]).to include("Project Stats")
        expect(result[:content]).to include("Ruby")
        expect(result[:content]).to include("15234 LOC")
        expect(result[:content]).to include("187 files")
      end
    end

    context "with full knowledge base" do
      before do
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "route", identifier: "GET /api/users",
          content: "GET /api/users", status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "symbol", scope_path: "app/models/user.rb",
          identifier: "User", content: "User model", status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "churn_hotspot", scope_path: "app/models/user.rb",
          identifier: "app/models/user.rb", content: "hotspot",
          metadata: { "revisions" => 30 }, status: "active")
        create(:decision_record, project: project, title: "Use JWT", status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "language_stat", identifier: "Ruby",
          content: "stats", metadata: { "code" => 10_000, "files" => 100 },
          status: "active")
      end

      it "includes all section types in correct order" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to eq(%i[routes symbols hotspots decisions stats])
        expect(result[:content]).to include("Codebase Context")
      end

      it "reports queries_made equal to number of sections" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:queries_made]).to eq(5)
      end
    end

    context "with stale artifacts" do
      before do
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "route", identifier: "GET /stale",
          content: "stale route", status: "stale")
      end

      it "excludes stale artifacts" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:content]).not_to include("GET /stale")
        expect(result[:sections]).to be_empty
      end
    end

    context "with artifacts from another project" do
      let(:other_project) { create(:project) }
      let(:other_run) { create(:collector_run, :completed, project_version: create(:project_version, project: other_project)) }

      before do
        create(:knowledge_artifact,
          project: other_project, collector_run: other_run,
          artifact_type: "route", identifier: "GET /other",
          content: "other", status: "active")
      end

      it "excludes artifacts from other projects" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:content]).not_to include("GET /other")
      end
    end
  end

  describe "token budget management" do
    it "respects a small token budget" do
      20.times do |i|
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "route",
          identifier: "GET /api/resource_#{i}/very_long_path_name_for_testing",
          content: "route #{i}", status: "active")
      end

      result = described_class.call(issue: issue, project: project, token_budget: 50)

      expect(result[:total_tokens]).to be <= 50
    end

    it "never exceeds the token budget" do
      20.times do |i|
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "route",
          identifier: "GET /api/resource_#{i}",
          content: "route #{i}", status: "active")
      end
      5.times do |i|
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "symbol", scope_path: "app/models/model_#{i}.rb",
          identifier: "Model#{i}", content: "model content", status: "active")
      end

      result = described_class.call(issue: issue, project: project, token_budget: 100)

      expect(result[:total_tokens]).to be <= 100
    end

    it "uses ENV-configured budget when no budget is passed" do
      original = ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"]
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = "2000"
      result = described_class.new(issue: issue, project: project)
      expect(result.token_budget).to eq(2000)
    ensure
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = original
    end

    it "defaults to 4000 tokens" do
      result = described_class.new(issue: issue, project: project)

      expect(result.token_budget).to eq(4000)
    end
  end
end
