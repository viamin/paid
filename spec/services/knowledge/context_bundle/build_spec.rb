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
      it "returns an empty result with accurate query count" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:content]).to eq("")
        expect(result[:sections]).to be_empty
        expect(result[:total_tokens]).to eq(0)
        expect(result[:queries_made]).to eq(Knowledge::ContextBundle::Build::SECTION_ORDER.size)
      end
    end

    context "with route artifacts" do
      before do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "route",
          identifier: "POST /api/users",
          content: "POST /api/users → UsersController#create",
          status: "active")
      end

      it "includes a routes section with controller info from content" do
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
          identifier: "app/models/user.rb::User",
          content: "class User",
          status: "active")
      end

      it "includes a symbols section" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:symbols)
        expect(result[:content]).to include("Related Code")
        expect(result[:content]).to include("app/models/user.rb::User")
        expect(result[:content]).to include("class User")
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

    context "with hotspots sorted by rank and revisions" do
      before do
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "churn_hotspot", identifier: "app/models/zzz.rb",
          scope_path: "app/models/zzz.rb", content: "hotspot",
          metadata: { "rank" => 1, "revisions" => 50 }, status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "churn_hotspot", identifier: "app/models/aaa.rb",
          scope_path: "app/models/aaa.rb", content: "hotspot",
          metadata: { "rank" => 3, "revisions" => 10 }, status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "churn_hotspot", identifier: "app/models/mmm.rb",
          scope_path: "app/models/mmm.rb", content: "hotspot",
          metadata: { "rank" => 1, "revisions" => 80 }, status: "active")
      end

      it "orders hotspots by rank then by revision count descending" do
        result = described_class.call(issue: issue, project: project)
        hotspot_section = result[:content][/### Hotspot Warning\n(.+?)(\n\n###|\z)/m, 1]
        lines = hotspot_section.split("\n")

        expect(lines[0]).to include("mmm.rb")  # rank 1, 80 revisions
        expect(lines[1]).to include("zzz.rb")  # rank 1, 50 revisions
        expect(lines[2]).to include("aaa.rb")  # rank 3, 10 revisions
      end
    end

    context "with more than 20 hotspots" do
      before do
        # Create 25 hotspots where the highest-ranked ones sort last alphabetically
        25.times do |i|
          identifier = format("zzz/file_%02d.rb", i)
          create(:knowledge_artifact,
            project: project, collector_run: collector_run,
            artifact_type: "churn_hotspot", identifier: identifier,
            scope_path: identifier, content: "hotspot",
            metadata: { "rank" => i + 1, "revisions" => 100 - i }, status: "active")
        end
        # Add a top-ranked hotspot that would be excluded by a LIMIT 20 + ORDER BY identifier
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "churn_hotspot", identifier: "zzz/top_hotspot.rb",
          scope_path: "zzz/top_hotspot.rb", content: "hotspot",
          metadata: { "rank" => 1, "revisions" => 200 }, status: "active")
      end

      it "includes the highest-ranked hotspots regardless of identifier ordering" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:sections]).to include(:hotspots)
        expect(result[:content]).to include("zzz/top_hotspot.rb")
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
          content: "GET /api/users → UsersController#index", status: "active")
        create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "symbol", scope_path: "app/models/user.rb",
          identifier: "app/models/user.rb::User", content: "class User", status: "active")
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

      it "reports queries_made as the number of section types queried" do
        result = described_class.call(issue: issue, project: project)

        expect(result[:queries_made]).to eq(Knowledge::ContextBundle::Build::SECTION_ORDER.size)
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

    it "falls back to default for blank ENV value" do
      original = ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"]
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = "  "
      result = described_class.new(issue: issue, project: project)
      expect(result.token_budget).to eq(4000)
    ensure
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = original
    end

    it "falls back to default for non-numeric ENV value" do
      original = ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"]
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = "abc"
      result = described_class.new(issue: issue, project: project)
      expect(result.token_budget).to eq(4000)
    ensure
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = original
    end

    it "falls back to default for zero or negative ENV value" do
      original = ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"]
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = "0"
      result = described_class.new(issue: issue, project: project)
      expect(result.token_budget).to eq(4000)
    ensure
      ENV["KNOWLEDGE_CONTEXT_TOKEN_BUDGET"] = original
    end
  end

  describe "truncation skips oversized sections" do
    it "includes a later smaller section when an earlier section is too large" do
      # Create a single route with many words so even one line exceeds the budget
      long_content = (1..60).map { |i| "word#{i}" }.join(" ")
      create(:knowledge_artifact,
        project: project, collector_run: collector_run,
        artifact_type: "route",
        identifier: "GET /api/huge",
        content: long_content,
        status: "active")
      create(:decision_record, project: project, title: "Use JWT", status: "active")

      # Budget too small for routes (single very long line) but enough for decisions
      result = described_class.call(issue: issue, project: project, token_budget: 40)

      # Without the fix, the bundle would break on the oversized route and miss decisions
      expect(result[:sections]).to include(:decisions)
      expect(result[:sections]).not_to include(:routes)
    end
  end
end
