# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# @spec PROJECT-READINESS-006 PROJECT-READINESS-012
RSpec.describe Projects::Readiness::Record do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  it "persists changed gaps and invalidates the Inbox cache" do
    project = create(:project, tdd_mode: "strict", primary_language: "Ruby")
    previous_version = Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

    Dir.mktmpdir do |repo_path|
      result = described_class.call(project:, repo_path:)

      expect(result.gaps.map(&:kind)).to include("missing_ci")
    end

    project.reload
    current_version = Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    expect(project.readiness_gaps).to include(hash_including("kind" => "missing_ci"))
    expect(project.readiness_evaluated_at).to be_present
    expect(current_version).to be > previous_version
  end

  it "does not invalidate the Inbox cache when the gap set is unchanged" do
    project = create(:project, tdd_mode: "strict", primary_language: "Ruby")

    Dir.mktmpdir do |repo_path|
      described_class.call(project:, repo_path:)
      first_version = Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      described_class.call(project:, repo_path:)

      expect(Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)).to eq(first_version)
    end
  end

  it "clears a repaired verification configuration on the next checkout evaluation" do
    project = create(:project, tdd_mode: "off", screenshot_settings: { "verification_enabled" => true })

    Dir.mktmpdir do |repo_path|
      described_class.call(project:, repo_path:)
      FileUtils.mkdir_p(File.join(repo_path, ".paid"))
      FileUtils.mkdir_p(File.join(repo_path, "bin"))
      File.write(File.join(repo_path, ".paid/screenshots.yml"), "routes:\n  - path: /\n    name: Home\n")
      File.write(File.join(repo_path, "bin/dev"), "#!/bin/sh\n")

      described_class.call(project:, repo_path:)
    end

    expect(project.reload.readiness_gaps).to be_empty
  end

  it "replaces a stale missing Godot command gap with target-checkout install-on-demand evidence" do # @spec PROJECT-READINESS-006 PROJECT-READINESS-013
    project = create(:project, tdd_mode: "strict", primary_language: "GDScript", readiness_gaps: [ {
      "kind" => "missing_test_command", "description" => "stale", "evidence" => { "ecosystem" => "godot" }
    } ])
    previous_version = Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)

    Dir.mktmpdir do |repo_path|
      FileUtils.mkdir_p(File.join(repo_path, ".github/workflows"))
      FileUtils.mkdir_p(File.join(repo_path, "tests"))
      FileUtils.mkdir_p(File.join(repo_path, "bin"))
      File.write(File.join(repo_path, ".github/workflows/gdunit4.yml"), "name: gdUnit4\n")
      File.write(File.join(repo_path, "bin/install-test-tools"), "#!/bin/sh\nexit 1\n")
      File.write(File.join(repo_path, "bin/test"), "#!/bin/sh\nexit 1\n")
      FileUtils.chmod("u+x", File.join(repo_path, "bin/install-test-tools"))
      FileUtils.chmod("u+x", File.join(repo_path, "bin/test"))

      described_class.call(project:, repo_path:)
    end

    expect(project.reload.readiness_gaps).to be_empty
    expect(Dashboard::CacheVersion.current(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)).to be > previous_version
  end
end
