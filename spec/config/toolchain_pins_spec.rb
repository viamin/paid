# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require Rails.root.join("scripts/lib/toolchain_pins")

# Guards the declarative pin registry that bin/update rewrites. The script
# itself only discovers a stale pattern when someone runs it; these examples
# fail in CI the moment a Dockerfile or workflow is reworded past its own
# registry entry.
RSpec.describe ToolchainPins, :no_db do
  # @spec TOOLCHAIN-PIN-001
  describe "registry shape" do
    it "declares at least one file entry for every managed group" do
      empty = described_class.groups.reject { |group| group.entries.any? }

      expect(empty.map(&:name)).to be_empty
    end

    it "points every entry at a file that exists" do
      missing = described_class.groups.flat_map do |group|
        group.entries.map(&:path).uniq.reject { |path| Rails.root.join(path).exist? }
      end

      expect(missing.uniq).to be_empty
    end

    it "gives every group an upstream source it can be resolved from" do
      sourceless = described_class.groups.reject { |group| group.source[:type] }

      expect(sourceless.map(&:name)).to be_empty
    end
  end

  # A registry path can outlive the file it names — a workflow gets deleted and
  # the registry is not updated with it. bin/update must hold that group and say
  # so rather than aborting, so one stale entry cannot stop every other check.
  #
  # @spec TOOLCHAIN-PIN-002
  describe "drift against a deleted file" do
    let(:group) { described_class.group("postgresql") }

    it "reports a registry path that no longer exists" do
      root = Pathname(Dir.mktmpdir)

      expect(group.missing_paths(root)).to match_array(group.entries.map(&:path).uniq)
    ensure
      FileUtils.remove_entry(root)
    end

    # A file that survives but whose pattern stops matching is the same drift as
    # a deleted one, and it must be caught before the value is read: callers
    # assume a matched entry yields a version string, so an unnoticed nil
    # propagates into a crash rather than a clear report.
    it "reports an entry whose file is present but whose pattern no longer matches" do
      root = Pathname(Dir.mktmpdir)
      group = described_class.group("postgresql")
      group.entries.map(&:path).uniq.each do |path|
        target = root.join(path)
        FileUtils.mkdir_p(target.dirname)
        target.write("nothing that any pattern here matches\n")
      end

      expect(group.missing_paths(root)).to be_empty
      expect(group.unmatched_entries(root)).not_to be_empty
    ensure
      FileUtils.remove_entry(root)
    end

    it "reads no value from an entry whose file is gone, instead of raising" do
      root = Pathname(Dir.mktmpdir)

      expect { group.entries.each { |entry| entry.current_value(root) } }.not_to raise_error
      expect(group.entries.map { |entry| entry.current_value(root) }.compact).to be_empty
    ensure
      FileUtils.remove_entry(root)
    end
  end

  # @spec TOOLCHAIN-PIN-002
  describe "pattern integrity" do
    it "matches every declared pattern against its file" do
      unmatched = described_class.groups.flat_map do |group|
        group.entries.reject { |entry| entry.matches?(Rails.root) }
          .map { |entry| "#{group.name}: #{entry.path} (#{entry.label})" }
      end

      expect(unmatched).to be_empty
    end

    it "captures a value for every declared pattern" do
      valueless = described_class.groups.flat_map do |group|
        group.entries.select { |entry| entry.matches?(Rails.root) }
          .reject { |entry| entry.current_value(Rails.root).to_s.match?(/\S/) }
          .map { |entry| "#{group.name}: #{entry.path} (#{entry.label})" }
      end

      expect(valueless).to be_empty
    end
  end

  # @spec TOOLCHAIN-PIN-003
  describe "consistency groups" do
    it "records one identical version across every file in a group" do
      divergent = described_class.groups.filter_map do |group|
        values = group.current_versions(Rails.root)
        next if values.values.uniq.size <= 1

        "#{group.name}: #{values.inspect}"
      end

      expect(divergent).to be_empty
    end

    # A group whose files disagree still needs rewriting even when its newest
    # file already matches upstream. Collapsing the group to one value would
    # report it up to date and leave the stragglers behind.
    #
    # @spec TOOLCHAIN-PIN-003
    it "reports a group as inconsistent when its files disagree" do
      root = Pathname(Dir.mktmpdir)
      group = described_class.group("postgresql")
      group.version_entries.each_with_index do |entry, index|
        path = root.join(entry.path)
        FileUtils.mkdir_p(path.dirname)
        path.write("    image: postgres:16.#{index.zero? ? 14 : 15}\n")
      end

      expect(group.consistent?(root)).to be(false)
      expect(group.current_versions(root).values.uniq).to contain_exactly("16.14", "16.15")
    ensure
      FileUtils.remove_entry(root)
    end

    it "reports a group as consistent when every file agrees" do
      expect(described_class.group("postgresql").consistent?(Rails.root)).to be(true)
    end

    it "records one identical checksum per architecture across every file in a group" do
      divergent = described_class.groups.flat_map do |group|
        group.current_checksums(Rails.root).filter_map do |arch, values|
          next if values.values.uniq.size <= 1

          "#{group.name}/#{arch}: #{values.inspect}"
        end
      end

      expect(divergent).to be_empty
    end
  end

  # @spec TOOLCHAIN-PIN-020
  describe "the postgresql group" do
    subject(:postgres) { described_class.group("postgresql") }

    it "covers every compose file and workflow service block that pins the server image" do
      image_paths = postgres.entries.select { |entry| entry.kind == :version }.map(&:path)

      expect(image_paths).to include(
        ".devcontainer/compose.yaml",
        "docker-compose.yml",
        ".github/workflows/ci.yml",
        ".github/workflows/system_tests.yml",
        ".github/workflows/test_prof.yml",
        ".github/workflows/pr-screenshots.yml",
        ".github/workflows/pr-screenshots-publish.yml",
        ".github/workflows/ephemeral_tests.yml"
      )
    end

    it "covers the client package pin in every image that installs one" do
      client_paths = postgres.entries.select { |entry| entry.kind == :client_package }.map(&:path)

      expect(client_paths).to contain_exactly(
        ".devcontainer/Dockerfile",
        "Dockerfile",
        "docker/agent/Dockerfile"
      )
    end

    it "names the PGDG distribution each client package targets" do
      distributions = postgres.entries
        .select { |entry| entry.kind == :client_package }
        .to_h { |entry| [ entry.path, entry.distribution ] }

      expect(distributions).to eq(
        ".devcontainer/Dockerfile" => "bookworm",
        "Dockerfile" => "trixie",
        "docker/agent/Dockerfile" => "noble"
      )
    end

    it "pins a client package whose version matches the pinned server version" do
      server = postgres.current_versions(Rails.root).values.first

      postgres.entries.select { |entry| entry.kind == :client_package }.each do |entry|
        expect(entry.current_value(Rails.root)).to start_with("#{server}-")
      end
    end
  end

  # @spec TOOLCHAIN-PIN-030
  describe "agent CLI ownership" do
    it "leaves every agent CLI version to the agent-harness contract" do
      paid_owned = described_class.groups.select { |group| group.ownership == :paid }.map(&:name)

      expect(paid_owned).not_to include("claude", "codex", "opencode", "kilocode", "omp", "pi")
    end

    it "records the agent CLIs as contract-owned so they are reported, not rewritten" do
      contract_owned = described_class.contract_packages.keys

      expect(contract_owned).to include("claude", "codex", "opencode", "kilocode", "omp")
    end

    # The gem release is the only version lever Paid controls over every
    # contract-owned agent CLI.
    #
    # @spec TOOLCHAIN-PIN-032
    it "locates the agent-harness version pin in the Gemfile" do
      pinned = Rails.root.join("Gemfile").read[described_class::AGENT_HARNESS_PATTERN, 2]

      expect(pinned).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  # @spec TOOLCHAIN-PIN-040
  describe "report-only runtimes" do
    subject(:pinned) do
      Rails.root.join(described_class::TOOL_VERSIONS_FILE).read.lines.to_h do |line|
        name, version = line.split(/\s+/, 2)
        [ name.to_s.strip, version.to_s.strip ]
      end
    end

    it "names a runtime that .tool-versions actually pins" do
      expect(pinned.keys).to include(*described_class::REPORT_ONLY_RUNTIMES)
    end

    it "covers every runtime .tool-versions pins, so none goes unreported" do
      expect(described_class::REPORT_ONLY_RUNTIMES).to match_array(pinned.keys)
    end
  end

  # @spec TOOLCHAIN-PIN-034
  describe "the devcontainer Oh My Pi defaults" do
    subject(:installer) { Rails.root.join(described_class::OH_MY_PI_INSTALLER).read }

    it "locates the pinned omp package version" do
      expect(installer[described_class::OH_MY_PI_PACKAGE_PATTERN, 2]).to match(/\A\d+\.\d+\.\d+\z/)
    end

    it "locates the pinned Bun runtime version" do
      expect(installer[described_class::OH_MY_PI_BUN_PATTERN, 2]).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end
end
