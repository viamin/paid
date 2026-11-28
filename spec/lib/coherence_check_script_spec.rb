# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

# Exercises the vendored LID coherence checker against fixture git
# repositories, covering the independently allocated spec-ID collisions
# observed during the PR drain (#5383).
# @spec LID-RUNS-008
# @spec LID-RUNS-009
# @spec LID-RUNS-010
RSpec.describe "bin/coherence-check.mjs" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  let(:script_path) { File.expand_path("../../bin/coherence-check.mjs", __dir__) }

  def git(dir, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end

  def init_fixture
    Dir.mktmpdir("coherence-check-spec", exec_tmpdir) do |dir|
      git(dir, "init", "-q", "-b", "main")
      git(dir, "config", "user.email", "spec@example.com")
      git(dir, "config", "user.name", "Spec")
      yield dir
    end
  end

  def run_script(dir, env = {})
    stdout, stderr, status = Open3.capture3({ "PATH" => ENV.fetch("PATH") }.merge(env), "node", script_path, chdir: dir)
    [ stdout.force_encoding("UTF-8"), stderr.force_encoding("UTF-8"), status ]
  end

  def write_spec_file(dir, segment, lines)
    path = File.join(dir, "docs/intent/#{segment}/#{segment}-specs.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  def spec_file_path(segment)
    "docs/intent/#{segment}/#{segment}-specs.md"
  end

  def line_of(dir, segment, id)
    path = File.join(dir, spec_file_path(segment))
    File.readlines(path, encoding: "UTF-8").index { |line| line.include?(id) } + 1
  end

  def read_spec_file(dir, segment)
    File.read(File.join(dir, spec_file_path(segment)), encoding: "UTF-8")
  end

  def commit_all(dir, message)
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", message)
  end

  def with_code_annotation(dir, relative_path, id)
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# frozen_string_literal: true\n\n# @spec #{id}\nclass Marker; end\n")
  end

  # Stable trailing content keeps the head and target additions in separate
  # merge hunks so the textual auto-merge succeeds without a Git conflict —
  # the exact shape of the PR5283 integration.
  def trailing_notes
    [
      "",
      "## Notes",
      "",
      "Claims below this point stay stable so merge hunks stay separate.",
      "",
      "Additional stable trailing material."
    ]
  end

  # Builds a fixture repository: a base commit on main, then a commit on the
  # feature branch, then a commit on main, leaving the feature branch checked
  # out. Yields the directory and the base SHA.
  def build_repo(segment, base:, feature: [], target: [], annotations: [])
    init_fixture do |dir|
      write_spec_file(dir, segment, base)
      commit_all(dir, "base")
      base_sha = git(dir, "rev-parse", "HEAD").strip

      git(dir, "checkout", "-qb", "feature")
      if feature.any?
        write_spec_file(dir, segment, feature)
        commit_all(dir, "feature claims")
      end

      git(dir, "checkout", "-q", "main")
      if target.any?
        write_spec_file(dir, segment, target)
        commit_all(dir, "target claims")
      end
      git(dir, "checkout", "-q", "feature")

      annotations.each { |path, id| with_code_annotation(dir, path, id) }

      yield dir, base_sha
    end
  end

  describe "independently allocated spec IDs colliding with the target branch" do
    let(:auth_base) do
      [
        "# EARS Specs: Subscription Runner Auth",
        "",
        "- [x] **SUBSCRIPTION-RUNNER-AUTH-007** — Existing auth claim."
      ]
    end
    let(:auth_feature) do
      auth_base + [
        "- [x] **SUBSCRIPTION-RUNNER-AUTH-008** — Materialization identity SHALL record the provider identity that materialized the credential."
      ]
    end
    let(:auth_target) do
      auth_base + [
        "- [x] **SUBSCRIPTION-RUNNER-AUTH-008** — Test Runner authentication-source readiness SHALL disclose the managed credential source."
      ]
    end
    let(:auth_annotations) do
      [
        [ "app/services/subscription_runners/materialize.rb", "SUBSCRIPTION-RUNNER-AUTH-008" ],
        [ "spec/services/subscription_runners/materialize_spec.rb", "SUBSCRIPTION-RUNNER-AUTH-008" ]
      ]
    end

    it "reports the head/target collision with file, ID, base, and head evidence" do
      build_repo("subscription-runner-auth",
        base: auth_base, feature: auth_feature, target: auth_target,
        annotations: auth_annotations) do |dir, base_sha|
        target_sha = git(dir, "rev-parse", "main").strip
        head_sha = git(dir, "rev-parse", "HEAD").strip
        segment = spec_file_path("subscription-runner-auth")
        head_line = "#{segment}:#{line_of(dir, "subscription-runner-auth", "SUBSCRIPTION-RUNNER-AUTH-008")}"
        stdout, _stderr, status = run_script(dir, { "LID_TARGET_BRANCH" => "main", "LID_BASE_SHA" => base_sha })

        expect(status.success?).to be(true)
        expect(stdout).to include("Collisions (1)")
        expect(stdout).to include("SUBSCRIPTION-RUNNER-AUTH-008")
        expect(stdout).to include("head: #{head_line}")
        expect(stdout).to include("target: #{segment}:")
        expect(stdout).to include("@spec in head: app/services/subscription_runners/materialize.rb")
        expect(stdout).to include("spec/services/subscription_runners/materialize_spec.rb")
        expect(stdout).to include(base_sha, head_sha, target_sha)
      end
    end
  end

  describe "the textual auto-merge that leaves duplicate declarations" do
    let(:base_claims) do
      [
        "# EARS Specs: Container Runtime",
        "",
        "- [x] **CONTAINER-RUNTIME-053** — Existing runtime claim."
      ]
    end
    let(:storage_claim) do
      [
        "- [x] **CONTAINER-RUNTIME-054** — Physical backing-storage admission SHALL validate the storage substrate."
      ]
    end
    let(:preparation_claim) do
      [
        "- [x] **CONTAINER-RUNTIME-054** — Transactional execution-preparation restoration SHALL restore the prepared execution state."
      ]
    end

    it "reports the collision and the integration-tree duplicate declarations" do
      build_repo("container-runtime",
        base: base_claims + trailing_notes,
        feature: base_claims + [ "" ] + storage_claim + trailing_notes,
        target: base_claims + trailing_notes + [ "" ] + preparation_claim) do |dir, base_sha|
        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("Collisions (1)")
        expect(stdout).to include("CONTAINER-RUNTIME-054")
        expect(stdout).to include("Duplicate declarations (1)")
        expect(stdout).to include("CONTAINER-RUNTIME-054: #{spec_file_path("container-runtime")}:")
        expect(stdout).to include("textual auto-merge")
        expect(stdout).to include("integration tree")
      end
    end
  end

  describe "legitimate shared and amended claims" do
    let(:seg_base) do
      [
        "# EARS Specs",
        "",
        "- [x] **SEG-001** — Shared claim kept unchanged.",
        "",
        "- [x] **SEG-002** — Claim the head amends.",
        "",
        "- [x] **SEG-003** — Stable claim."
      ]
    end
    let(:seg_feature) do
      [
        "# EARS Specs",
        "",
        "- [x] **SEG-001** — Shared claim kept unchanged.",
        "",
        "- [x] **SEG-002** — Claim the head amends, with revised wording.",
        "",
        "- [x] **SEG-003** — Stable claim.",
        "",
        "- [x] **SEG-009** — Unique head addition."
      ]
    end
    let(:seg_target) do
      [
        "# EARS Specs",
        "",
        "- [x] **SEG-001** — Shared claim kept unchanged.",
        "",
        "- [x] **SEG-002** — Claim the head amends.",
        "",
        "- [x] **SEG-003** — Stable claim.",
        "",
        "- [x] **SEG-010** — Unique target addition."
      ]
    end

    it "reports no findings for an amendment, an unchanged shared claim, and unique parallel additions" do
      build_repo("seg", base: seg_base, feature: seg_feature, target: seg_target) do |dir, base_sha|
        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("No collisions detected.")
        expect(stdout).to include("No duplicate declarations in the integration tree.")
        expect(stdout).not_to include("Collisions (")
        expect(stdout).not_to include("Duplicate declarations (")
      end
    end

    it "does not flag a target declaration the head adopted byte-identically" do
      adopted = "- [x] **SEG-012** — Claim both sides carry with identical text."
      build_repo("seg",
        base: [ "# EARS Specs", "", "- [x] **SEG-001** — Base claim." ],
        feature: [ "# EARS Specs", "", "- [x] **SEG-001** — Base claim.", "", adopted ],
        target: [ "# EARS Specs", "", "- [x] **SEG-001** — Base claim.", "", adopted ]) do |dir, base_sha|
        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("No collisions detected.")
      end
    end
  end

  describe "already-integrated branches" do
    let(:base_claims) do
      [
        "# EARS Specs",
        "",
        "- [x] **CONTAINER-RUNTIME-053** — Existing runtime claim."
      ]
    end
    let(:feature_claims) do
      base_claims + [
        "",
        "- [x] **CONTAINER-RUNTIME-054** — Physical backing-storage admission SHALL validate the storage substrate."
      ] + trailing_notes
    end
    let(:target_claims) do
      base_claims + trailing_notes + [
        "",
        "- [x] **CONTAINER-RUNTIME-054** — Transactional execution-preparation restoration SHALL restore the prepared execution state."
      ]
    end

    it "does not flag a reconciled merge that renumbered the incoming claim" do
      build_repo("container-runtime", base: base_claims + trailing_notes,
        feature: feature_claims, target: target_claims) do |dir, base_sha|
        git(dir, "merge", "-q", "--no-edit", "main")
        # Reconcile: the incoming claim is renumbered to 055, preserving the
        # merged target's 054 — the state PR5283's integration ended in.
        reconciled = read_spec_file(dir, "container-runtime").sub(
          "- [x] **CONTAINER-RUNTIME-054** — Physical backing-storage admission SHALL validate the storage substrate.",
          "- [x] **CONTAINER-RUNTIME-055** — Physical backing-storage admission SHALL validate the storage substrate."
        )
        File.write(File.join(dir, spec_file_path("container-runtime")), reconciled)
        commit_all(dir, "reconcile: renumber incoming claim to 055")

        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("No collisions detected.")
        expect(stdout).to include("No duplicate declarations in the integration tree.")
      end
    end

    it "flags duplicate declarations left by an unreconciled textual auto-merge" do
      build_repo("container-runtime", base: base_claims + trailing_notes,
        feature: feature_claims, target: target_claims) do |dir, base_sha|
        # Textual auto-merge succeeds without a conflict and silently keeps
        # both declarations. Nobody reconciles the duplicate.
        git(dir, "merge", "-q", "--no-edit", "main")

        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("Duplicate declarations (1)")
        expect(stdout).to include("CONTAINER-RUNTIME-054: #{spec_file_path("container-runtime")}:")
      end
    end
  end

  describe "uncommitted working-tree state" do
    let(:seg_base) { [ "# EARS Specs", "", "- [x] **SEG-001** — Base claim." ] }
    let(:uncommitted_claims) do
      [
        "# EARS Specs",
        "",
        "- [x] **SEG-001** — Base claim.",
        "",
        "- [x] **SEG-004** — Committed head claim.",
        "",
        "- [x] **SEG-011** — Uncommitted head claim colliding with the target."
      ].join("\n") + "\n"
    end

    it "includes uncommitted declarations without disturbing the index or working tree" do
      build_repo("seg",
        base: seg_base,
        feature: seg_base + [ "", "- [x] **SEG-004** — Committed head claim." ],
        target: seg_base + [ "", "- [x] **SEG-011** — Target claim for the uncommitted head claim." ]) do |dir, base_sha|
        # The agent's uncommitted work declares SEG-011 for a different claim.
        File.write(File.join(dir, spec_file_path("seg")), uncommitted_claims)

        stdout, _stderr, status = run_script(dir, {
          "LID_TARGET_BRANCH" => "main",
          "LID_BASE_SHA" => base_sha
        })

        expect(status.success?).to be(true)
        expect(stdout).to include("Collisions (1)")
        expect(stdout).to include("SEG-011")
        expect(stdout).to include("Duplicate declarations (1)")

        # The snapshot path must not stage, commit, reset, or clean anything.
        expect(git(dir, "diff", "--name-only", "--cached")).to be_empty
        expect(read_spec_file(dir, "seg")).to include("Uncommitted head claim")
        expect(git(dir, "status", "--porcelain")).to include(" M #{spec_file_path("seg")}")
      end
    end
  end

  describe "target and base resolution" do
    let(:seg_base) { [ "# EARS Specs", "", "- [x] **SEG-001** — Base claim." ] }

    it "auto-detects the local default branch when run without env configuration" do
      build_repo("seg",
        base: seg_base,
        feature: seg_base + [ "", "- [x] **SEG-021** — Head claim." ],
        target: seg_base + [ "", "- [x] **SEG-021** — Target claim with different text." ]) do |dir, _base_sha|
        stdout, _stderr, status = run_script(dir)

        expect(status.success?).to be(true)
        expect(stdout).to include("Collisions (1)")
        expect(stdout).to include("SEG-021")
      end
    end

    it "skips the section with an advisory note when no target ref resolves" do
      init_fixture do |dir|
        write_spec_file(dir, "seg", [
          "# EARS Specs",
          "",
          "- [x] **SEG-001** — Base claim."
        ])
        commit_all(dir, "base")
        git(dir, "checkout", "-qb", "feature")

        stdout, _stderr, status = run_script(dir, { "LID_TARGET_BRANCH" => "no-such-branch" })

        expect(status.success?).to be(true)
        expect(stdout).to include("Collision check skipped:")
        expect(stdout).not_to include("Collisions (")
      end
    end

    it "skips the section with an advisory note when the base is unresolvable" do
      init_fixture do |dir|
        write_spec_file(dir, "seg", [
          "# EARS Specs",
          "",
          "- [x] **SEG-001** — Base claim."
        ])
        commit_all(dir, "base")

        # Orphan branch: no common ancestor with main, so merge-base fails.
        git(dir, "checkout", "-q", "--orphan", "orphan")
        git(dir, "rm", "-rqf", ".")
        write_spec_file(dir, "seg", [
          "# EARS Specs",
          "",
          "- [x] **OTHER-001** — Unrelated claim."
        ])
        commit_all(dir, "orphan root")

        stdout, _stderr, status = run_script(dir, { "LID_TARGET_BRANCH" => "main" })

        expect(status.success?).to be(true)
        expect(stdout).to include("Collision check skipped:")
        expect(stdout).not_to include("Collisions (")
      end
    end

    it "skips the section silently outside a git repository" do
      Dir.mktmpdir("coherence-check-nogit", exec_tmpdir) do |dir|
        write_spec_file(dir, "seg", [
          "# EARS Specs",
          "",
          "- [x] **SEG-001** — Claim."
        ])

        stdout, _stderr, status = run_script(dir)

        expect(status.success?).to be(true)
        expect(stdout).to include("LID Coherence Report")
        expect(stdout).not_to include("Collisions (")
      end
    end
  end
end
