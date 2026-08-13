# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Installations::RepositoriesReconciler do
  let(:account) { create(:account) }
  let(:installation) do
    create(:github_installation, account: account,
           accessible_repositories: [
             { "id" => 1, "full_name" => "acme/widgets", "name" => "widgets",
               "owner" => "acme", "default_branch" => "main", "private" => false },
             { "id" => 2, "full_name" => "acme/gadgets", "name" => "gadgets",
               "owner" => "acme", "default_branch" => "main", "private" => false }
           ])
  end

  def repo_payload(repos, action:)
    {
      "action" => action,
      "installation" => { "id" => installation.github_installation_id },
      "repositories_added" => action == "added" ? repos : nil,
      "repositories_removed" => action == "removed" ? repos : nil
    }
  end

  it "merges new repositories on added events" do
    new_repo = { "id" => 3, "full_name" => "acme/sprockets", "name" => "sprockets",
                 "owner" => { "login" => "acme" }, "default_branch" => "main",
                 "private" => false }

    described_class.call(
      installation: installation,
      payload: repo_payload([ new_repo ], action: "added")
    )

    installation.reload
    expect(installation.accessible_repositories.map { |r| r["full_name"] })
      .to contain_exactly("acme/widgets", "acme/gadgets", "acme/sprockets")
    expect(installation.repositories_synced_at).to be_present
  end

  it "removes repositories on removed events" do
    removed = { "id" => 2, "full_name" => "acme/gadgets" }

    described_class.call(
      installation: installation,
      payload: repo_payload([ removed ], action: "removed")
    )

    installation.reload
    expect(installation.accessible_repositories.map { |r| r["full_name"] })
      .to contain_exactly("acme/widgets")
  end

  it "no-ops on unknown actions" do
    described_class.call(
      installation: installation,
      payload: { "action" => "renamed", "installation" => { "id" => installation.github_installation_id } }
    )

    installation.reload
    expect(installation.accessible_repositories.size).to eq(2)
  end
end
