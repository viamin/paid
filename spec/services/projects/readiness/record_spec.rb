# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# @spec PROJECT-READINESS-006
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
end
