# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListInboxEntries do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let!(:issues) do
    create_list(:issue, 3, :needs_input, project:, needs_input_questions: [ "What should happen?" ])
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "lists a bounded, list-safe actionable projection with cursor pagination" do
    first_page = described_class.new(user:, session:).call(kind: "clarifying_questions", limit: 2)

    expect(first_page.fetch(:entries)).to all(include(kind: "clarifying_questions", summary: be_present))
    expect(first_page.fetch(:entries)).to all(have_key(:action_url))
    expect(first_page.fetch(:entries)).to all(satisfy { |entry| !entry.key?(:progress) && !entry.key?(:history) })
    expect(first_page.fetch(:next_cursor)).to eq(first_page.fetch(:entries).last.fetch(:id))

    second_page = described_class.new(user:, session:).call(
      kind: "clarifying_questions", limit: 2, cursor: first_page.fetch(:next_cursor)
    )
    expect(second_page.fetch(:entries).map { |entry| entry.fetch(:id) }).to eq(
      issues.map { |issue| "clarifying_questions:#{issue.id}" } - first_page.fetch(:entries).map { |entry| entry.fetch(:id) }
    )
    expect(second_page).not_to have_key(:next_cursor)
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "treats a blank limit as the default page, like the REST Inbox API" do
    result = described_class.new(user:, session:).call(kind: "clarifying_questions", limit: nil)

    expect(result.fetch(:entries).map { |entry| entry.fetch(:id) })
      .to eq(issues.map { |issue| "clarifying_questions:#{issue.id}" })
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "filters by an accessible project and rejects a project outside the account" do
    other_account = create(:account)
    other_project = create(:project, account: other_account)
    tool = described_class.new(user:, session:)

    scoped = tool.call(kind: "clarifying_questions", project_id: project.id).fetch(:entries)
    expect(scoped.map { |entry| entry.fetch(:id) })
      .to match_array(issues.map { |issue| "clarifying_questions:#{issue.id}" })

    expect { tool.call(project_id: other_project.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  context "with a merge_approval request held back by a disabled phase" do
    let(:governed_project) do
      create(
        :project,
        account:,
        created_by: user,
        auto_pick_enabled: true,
        active: true,
        auto_merge_mode: "all",
        owner_reviewer_login: "viamin",
        owner: "acme",
        repo: "governed"
      )
    end

    let!(:pull_request) do
      create(
        :issue,
        :pull_request,
        project: governed_project,
        labels: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ],
        auto_merge_evaluated_at: nil,
        auto_merge_blockers: nil
      )
    end

    before do
      FeatureFlags.enable!(:automation_phases, project: governed_project)
      governed_project.update!(Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      })
    end

    # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
    it "lists another kind and surfaces entries held back by a disabled phase" do
      tool = described_class.new(user:, session:)

      expect(tool.call(kind: "merge_approval").fetch(:entries)).to be_empty

      held = tool.call(
        kind: "merge_approval", scope: Inbox::Queue::DISABLED_PHASES_SCOPE
      ).fetch(:entries)
      expect(held.map { |entry| entry.fetch(:id) }).to eq([ "merge_approval:#{pull_request.id}" ])
      expect(held.first).to include(kind: "merge_approval", summary: be_present)
    end
  end

  # @spec MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-003
  it "honors actionable defaults, removals, and duplicate reads" do
    other_user = create(:user, account:)
    hidden_project = create(:project, account:, created_by: other_user)
    hidden_issue = create(:issue, :needs_input, project: hidden_project, needs_input_questions: [ "Hidden" ])
    tool = described_class.new(user:, session:)
    entry_id = "clarifying_questions:#{issues.first.id}"

    baseline = tool.call(kind: "clarifying_questions")
    expect(baseline.fetch(:entries).map { |entry| entry.fetch(:id) }).to include(entry_id)
    expect(baseline.fetch(:entries).map { |entry| entry.fetch(:id) }).not_to include("clarifying_questions:#{hidden_issue.id}")
    expect(tool.call(kind: "clarifying_questions")).to eq(baseline)

    entry = Inbox::FindEntry.call(user:, entry_id:)
    Inbox::Removals::Remove.call(entry:, user:)
    expect(tool.call(kind: "clarifying_questions").fetch(:entries).map { |item| item.fetch(:id) }).not_to include(entry_id)
    expect(tool.call(kind: "clarifying_questions", scope: Inbox::Queue::REMOVED_SCOPE)
      .fetch(:entries).map { |item| item.fetch(:id) }).to include(entry_id)
  end
end
