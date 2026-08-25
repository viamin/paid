# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::SyncDefaults do
  subject(:sync_defaults) { described_class.call(definitions:) }

  let(:definitions) do
    [
      {
        slug: "chat.system_prompt",
        name: "Chat System Prompt",
        description: "Default chat behavior",
        category: "planning",
        template: "Current shipped guidance",
        variables: []
      }
    ]
  end

  # @spec PROMPT-DEFAULT-SYNC-001
  it "creates a missing global prompt with its initial current version" do
    result = sync_defaults
    prompt = Prompt.global.find_by!(slug: "chat.system_prompt")

    expect(prompt.current_version).to have_attributes(
      template: "Current shipped guidance",
      variables: [],
      version: 1,
      created_by: "seed"
    )
    expect(result).to have_attributes(prompts_created: 1, versions_created: 1, unchanged: 0)
  end

  # @spec PROMPT-DEFAULT-SYNC-001
  it "creates and promotes a version when the shipped definition changes" do
    prompt = create(:prompt, :global, :planning, slug: "chat.system_prompt")
    original = prompt.create_version!(template: "Stale guidance", variables: [])

    result = sync_defaults

    expect(prompt.reload.current_version).to have_attributes(template: "Current shipped guidance", version: 2)
    expect(prompt.prompt_versions).to include(original)
    expect(result).to have_attributes(prompts_created: 0, versions_created: 1, unchanged: 0)
  end

  # @spec PROMPT-DEFAULT-SYNC-002
  it "does not create a version for a normalized equivalent definition" do
    prompt = create(:prompt, :global, :planning, slug: "chat.system_prompt")
    current = prompt.create_version!(template: "  Current shipped guidance\n", variables: [])

    result = sync_defaults

    expect(prompt.reload.current_version).to eq(current)
    expect(prompt.prompt_versions.count).to eq(1)
    expect(result).to have_attributes(prompts_created: 0, versions_created: 0, unchanged: 1)
  end

  # @spec PROMPT-DEFAULT-SYNC-003
  it "leaves account and project overrides unchanged" do
    account = create(:account)
    project = create(:project, account:)
    account_prompt = create(:prompt, :planning, account:, project: nil, slug: "chat.system_prompt")
    project_prompt = create(:prompt, :planning, account:, project:, slug: "chat.system_prompt")
    account_version = account_prompt.create_version!(template: "Account guidance", variables: [])
    project_version = project_prompt.create_version!(template: "Project guidance", variables: [])

    sync_defaults

    expect(account_prompt.reload.current_version).to eq(account_version)
    expect(project_prompt.reload.current_version).to eq(project_version)
  end

  # @spec PROMPT-DEFAULT-SYNC-004
  it "holds a transaction-scoped database advisory lock while synchronizing definitions" do
    connection = ActiveRecord::Base.connection
    allow(connection).to receive(:execute).and_call_original
    expect(connection).to receive(:execute)
      .with(described_class::ADVISORY_LOCK_SQL)
      .and_call_original

    sync_defaults

    prompt = Prompt.global.find_by!(slug: "chat.system_prompt")
    expect(prompt.prompt_versions.reload.pluck(:version)).to eq([ 1 ])
  end

  # @spec PROMPT-DEFAULT-SYNC-001, PROMPT-DEFAULT-SYNC-004
  it "rolls back every definition when one definition is invalid" do
    invalid_definition = definitions.first.merge(slug: "invalid.prompt", category: "invalid")

    expect { described_class.call(definitions: [ definitions.first, invalid_definition ]) }
      .to raise_error(ActiveRecord::RecordInvalid)

    expect(Prompt.global.where(slug: [ "chat.system_prompt", "invalid.prompt" ])).to be_empty
  end

  # @spec PROMPT-DEFAULT-SYNC-006
  it "uses the synchronization service when loading the shipped prompt seeds" do
    load Rails.root.join("db/seeds/prompts.rb")

    prompt = Prompt.global.find_by!(slug: "chat.system_prompt")
    expect(prompt.current_version.template).to include("You are an AI assistant helping manage software projects via Paid")
  end

  # @spec PROMPT-DEFAULT-SYNC-006, CHAT-API-012
  it "seeds the chat system prompt with knowledge-search-first discovery guidance" do
    load Rails.root.join("db/seeds/prompts.rb")

    template = Prompt.global.find_by!(slug: "chat.system_prompt").current_version.template
    expect(template).to include("`search_code`")
    expect(template).to include("`read_repo_file`")
    expect(template).to include("`grep_repo`")
    expect(template).not_to include("get_file_content")
  end
end
