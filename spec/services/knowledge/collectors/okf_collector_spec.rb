# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-OKF-001
# @spec KNOWLEDGE-OKF-002
# @spec KNOWLEDGE-OKF-004
RSpec.describe Knowledge::Collectors::OkfCollector do
  subject(:collector) do
    described_class.new(project:, project_version:, collector_run:, options: { scan_path: fixture_path.to_s })
  end

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project:) }
  let(:collector_run) { create(:collector_run, project_version:, collector_type: "okf") }
  let(:fixture_path) { Pathname(RSpec.current_example.metadata.fetch(:tmpdir)) }

  around do |example|
    Dir.mktmpdir do |dir|
      example.metadata[:tmpdir] = dir
      example.run
    end
  end

  def git_repo!
    system("git", "init", "-q", fixture_path.to_s, out: File::NULL, err: File::NULL)
  end

  def commit_okf_file!(relative_path)
    identity = {
      "GIT_AUTHOR_NAME" => "OKF Author",
      "GIT_AUTHOR_EMAIL" => "okf@example.com",
      "GIT_COMMITTER_NAME" => "OKF Author",
      "GIT_COMMITTER_EMAIL" => "okf@example.com"
    }
    system(identity, "git", "-C", fixture_path.to_s, "add", relative_path, out: File::NULL, err: File::NULL)
    system(identity, "git", "-C", fixture_path.to_s, "commit", "-q", "-m", "Add #{relative_path}", out: File::NULL, err: File::NULL)
  end

  describe "#collector_type" do
    it { expect(collector.collector_type).to eq("okf") }
  end

  describe "#collect" do
    context "when the repository has no OKF bundle" do
      it "skips the collector" do
        expect { collector.collect }.to raise_error(Knowledge::SkipCollector, /no OKF bundle found/)
      end
    end

    context "when the repository has an .okf bundle" do
      it "indexes markdown concepts with frontmatter as curated artifacts" do
        fixture_path.join(".okf/concepts").mkpath
        fixture_path.join(".okf/concepts/auth.md").write(
          "---\ntitle: Auth flows\ntype: concept\ntags:\n  - auth\n  - security\n---\n\nUsers sign in with SSO.\n"
        )

        artifacts = collector.collect

        expect(artifacts.length).to eq(1)
        artifact = artifacts.first
        expect(artifact[:artifact_type]).to eq("okf_concept")
        expect(artifact[:scope_path]).to eq(".okf/concepts/auth.md")
        expect(artifact[:identifier]).to eq("Auth flows")
        expect(artifact[:content]).to eq("Users sign in with SSO.")
        expect(artifact[:metadata]).to include(
          "source_path" => ".okf/concepts/auth.md",
          "concept_type" => "concept",
          "title" => "Auth flows",
          "tags" => %w[auth security]
        )
      end

      it "preserves the body as curated chunks" do
        fixture_path.join(".okf/concepts").mkpath
        fixture_path.join(".okf/concepts/auth.md").write(
          "---\ntitle: Auth flows\ntype: concept\ntags:\n  - auth\n---\n\nUsers sign in with SSO.\n"
        )

        chunks = collector.collect.first[:chunks]

        expect(chunks).to contain_exactly(
          a_hash_including(chunk_type: "summary", sequence: 0, scope_tags: containing_exactly("okf", "concept")),
          a_hash_including(chunk_type: "definition", content: "Users sign in with SSO.", sequence: 1)
        )
      end

      it "derives concept type from the bundle subdirectory when frontmatter omits it" do
        fixture_path.join(".okf/decisions").mkpath
        fixture_path.join(".okf/decisions/postgres.md").write(
          "---\ntitle: Use Postgres\n---\n\nPostgres is the canonical store.\n"
        )

        artifact = collector.collect.first

        expect(artifact.dig(:metadata, "concept_type")).to eq("decisions")
        expect(artifact.dig(:metadata, "title")).to eq("Use Postgres")
      end

      it "falls back to the file basename for a missing title and string tags" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/deploy-runbook.md").write(
          "---\ntags: deploy, runbook\n---\n\nRolling deploys via kamal.\n"
        )

        artifact = collector.collect.first

        expect(artifact[:identifier]).to eq("deploy-runbook")
        expect(artifact.dig(:metadata, "title")).to eq("deploy-runbook")
        expect(artifact.dig(:metadata, "tags")).to eq(%w[deploy runbook])
        expect(artifact.dig(:metadata, "concept_type")).to eq("concept")
      end

      it "truncates frontmatter titles that exceed the identifier limit" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/long-title.md").write("---\ntitle: #{'x' * 600}\n---\n\nBody.\n")

        artifact = collector.collect.first

        expect(artifact[:identifier].length).to eq(500)
      end

      it "does not enumerate markdown files outside the bundle" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/concept.md").write("---\ntitle: In bundle\n---\n\nBody.\n")
        fixture_path.join("docs").mkpath
        fixture_path.join("docs", "readme.md").write("---\ntitle: Outside\n---\n\nBody.\n")

        artifacts = collector.collect

        expect(artifacts.pluck(:identifier)).to eq([ "In bundle" ])
      end

      it "captures last commit metadata for committed concept files" do
        git_repo!
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/review.md").write("---\ntitle: Review gates\n---\n\nPRs need review.\n")
        commit_okf_file!(".okf/review.md")

        last_commit = collector.collect.first[:metadata]["last_commit"]

        expect(last_commit).to include(
          "sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
          "author" => "OKF Author",
          "subject" => "Add .okf/review.md"
        )
        expect(Time.parse(last_commit["date"])).to be_within(60).of(Time.current)
      end

      it "omits last commit metadata when git history is unavailable" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/review.md").write("---\ntitle: Review gates\n---\n\nPRs need review.\n")

        metadata = collector.collect.first[:metadata]

        expect(metadata).not_to have_key("last_commit")
      end
    end

    context "with an explicitly configured bundle path" do
      it "indexes the configured path" do
        fixture_path.join("knowledge/okf").mkpath
        fixture_path.join("knowledge/okf/billing.md").write("---\ntitle: Billing model\n---\n\nUsage-based.\n")

        configured = described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { scan_path: fixture_path.to_s, okf_paths: [ "knowledge/okf" ] }
        )

        expect(configured.collect.pluck(:identifier)).to eq([ "Billing model" ])
      end

      it "rejects configured paths that escape the repository" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/in-bundle.md").write("---\ntitle: In bundle\n---\n\nBody.\n")

        escaping = described_class.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: { scan_path: fixture_path.to_s, okf_paths: [ "../outside" ] }
        )

        expect(escaping.collect.pluck(:identifier)).to eq([ "In bundle" ])
      end

      it "rejects bundle roots that are symlinks pointing outside the repository" do
        Dir.mktmpdir do |outside|
          File.write(File.join(outside, "leaked.md"), "---\ntitle: Leaked concept\n---\n\nOutside body.\n")

          okf_path = fixture_path.join(".okf")
          FileUtils.rm_rf(okf_path)
          File.symlink(outside, okf_path)

          expect { collector.collect }.to raise_error(Knowledge::SkipCollector, /no OKF bundle found/)
        end
      end
    end

    context "with invalid OKF files" do
      it "records findings on the collector run and still indexes valid files" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/good.md").write("---\ntitle: Good concept\n---\n\nValid body.\n")
        fixture_path.join(".okf/bad-yaml.md").write("---\ntitle: Broken\n  bad: [unclosed\n---\n\nBody.\n")
        fixture_path.join(".okf/no-frontmatter.md").write("# Just markdown\n\nNo frontmatter.\n")
        fixture_path.join(".okf/list-frontmatter.md").write("---\n- one\n- two\n---\n\nBody.\n")
        fixture_path.join(".okf/empty-body.md").write("---\ntitle: Empty\n---\n\n")

        artifacts = collector.collect

        expect(artifacts.pluck(:identifier)).to eq([ "Good concept" ])
        findings = collector_run.reload.metadata.fetch("findings")
        paths = findings.pluck("path")
        expect(paths).to contain_exactly(
          ".okf/bad-yaml.md", ".okf/no-frontmatter.md",
          ".okf/list-frontmatter.md", ".okf/empty-body.md"
        )
        expect(findings).to all(include("severity" => "error", "reason" => a_kind_of(String)))
      end

      it "does not raise when every file in the bundle is invalid" do
        fixture_path.join(".okf").mkpath
        fixture_path.join(".okf/broken.md").write("no frontmatter at all")

        expect(collector.collect).to eq([])
        expect(collector_run.reload.metadata.fetch("findings").length).to eq(1)
      end
    end
  end

  describe "end-to-end via CollectorRunner" do
    let(:stub_collector_class) do
      Class.new(Knowledge::BaseCollector) do
        def collect
          []
        end

        def collector_type
          "stub_collector"
        end
      end
    end

    before do
      Knowledge::CollectorRunner.reset_registry!
      Knowledge::CollectorRunner.register("okf", described_class)
      Knowledge::CollectorRunner.register("stub_collector", stub_collector_class)
    end

    after do
      Knowledge::CollectorRunner.reset_registry!
    end

    def run_collector(commit_sha)
      Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        options: { scan_path: fixture_path.to_s }
      )
    end

    it "skips OKF collection without a bundle while other collectors complete" do
      result = run_collector("1" * 40)

      statuses = result[:results].to_h { |r| [ r[:collector_type], r[:status] ] }
      expect(statuses).to eq("okf" => "skipped", "stub_collector" => "completed")
      expect(project.knowledge_artifacts.by_type("okf_concept")).to be_empty
    end

    it "stores searchable curated artifacts and findings alongside other collectors" do
      fixture_path.join(".okf").mkpath
      fixture_path.join(".okf/concept.md").write("---\ntitle: Stored concept\n---\n\nCurated body.\n")
      fixture_path.join(".okf/broken.md").write("no frontmatter")

      result = run_collector("2" * 40)

      statuses = result[:results].to_h { |r| [ r[:collector_type], r[:status] ] }
      expect(statuses).to eq("okf" => "completed", "stub_collector" => "completed")

      artifact = project.knowledge_artifacts.active.by_type("okf_concept").sole
      expect(artifact.identifier).to eq("Stored concept")
      expect(artifact.knowledge_chunks.active.pluck(:chunk_type)).to contain_exactly("summary", "definition")

      okf_run = CollectorRun.find_by!(collector_type: "okf")
      expect(okf_run.metadata.fetch("findings").pluck("path")).to eq([ ".okf/broken.md" ])
    end
  end
end
