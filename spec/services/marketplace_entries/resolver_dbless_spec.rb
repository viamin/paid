# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Resolver, :no_db do
  it "uses the preloaded rule collection instead of relation scopes for an automatically matched entry" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "automatic" ])
    expect(results.map(&:reason)).to eq([ "Matched automatically" ])
  end

  it "does not auto-attach when automatic attachment is disabled" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results).to be_empty
  end

  it "attaches automatic and team-default entries for opted-in users" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    automatic_entry = build_entry(id: 7)
    team_default_entry = build_entry(
      id: 8,
      rules: [ build_rule(mode: "team_default", enabled: true, position: 0, id: 4, rationale: "Required by the account") ]
    )

    resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ automatic_entry, team_default_entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ automatic_entry, team_default_entry ])
    expect(results.map(&:source)).to eq([ "automatic", "team_default" ])
  end

  it "does not attach unrelated team-default entries when the user also makes manual selections" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    automatic_entry = build_entry(id: 7)
    manual_entry = build_entry(id: 8, rules: [])
    team_default_entry = build_entry(
      id: 9,
      rules: [ build_rule(mode: "team_default", enabled: true, position: 0, id: 4, rationale: "Required by the account") ]
    )

    resolver = described_class.new(
      project:,
      agent_run:,
      manual_entry_ids: [ manual_entry.id ],
      auto_attach_enabled: true
    )
    allow(resolver).to receive(:candidate_entries).and_return([ automatic_entry, manual_entry, team_default_entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ automatic_entry, manual_entry ])
    expect(results.map(&:source)).to eq([ "automatic", "manual" ])
  end

  it "upgrades to manual when the user explicitly selects an automatically matched entry" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry(id: 7)

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ entry.id ], auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "manual" ])
  end

  it "preserves explicit manual selection order when candidate entries are returned in a different order" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    first_entry = build_entry(id: 7, rules: [])
    second_entry = build_entry(id: 8, rules: [])

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ second_entry.id, first_entry.id ])
    allow(resolver).to receive(:candidate_entries).and_return([ first_entry, second_entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ second_entry, first_entry ])
    expect(results.map(&:source)).to eq([ "manual", "manual" ])
  end

  it "attaches an automatic entry without manual selection when auto-attach is enabled" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry(id: 7)

    resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "automatic" ])
  end

  it "attaches account-required automatic and team-default entries without per-entry manual selection" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    automatic_entry = build_entry(id: 7)
    team_default_entry = build_entry(
      id: 8,
      rules: [ build_rule(mode: "team_default", enabled: true, position: 0, id: 4, rationale: "Required by the account") ]
    )

    resolver = described_class.new(project:, agent_run:, account_auto_attach_required: true)
    allow(resolver).to receive(:candidate_entries).and_return([ automatic_entry, team_default_entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ automatic_entry, team_default_entry ])
    expect(results.map(&:source)).to eq([ "automatic", "team_default" ])
  end

  it "preserves manual attachments when auto-attach is disabled" do
    project = project_double
    attachments = agent_run_marketplace_entries_with_manual
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ entry.id ])
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:source)).to eq([ "manual" ])
  end

  it "treats an explicit empty manual selection as clearing manual attachments" do
    project = project_double
    attachments = agent_run_marketplace_entries_with_manual
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [])
    allow(resolver).to receive(:candidate_entries).and_return([])

    results = resolver.call

    expect(results).to be_empty
    expect(attachments).not_to have_received(:where)
  end

  it "fails closed when a manually selected entry cannot be resolved for the run" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ 7 ])
    allow(resolver).to receive(:candidate_entries).and_return([])

    expect { resolver.call }.to raise_error(
      ActiveRecord::RecordNotFound,
      /Selected marketplace entries are unavailable or incompatible/
    )
  end

  it "upgrades to manual when the user explicitly selects an entry that also matches automatic and team_default rules" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry(
      rules: [
        build_rule(mode: "automatic", enabled: true, position: 0, id: 3, rationale: "Matched automatically"),
        build_rule(mode: "team_default", enabled: true, position: 1, id: 2, rationale: "Matched as team default")
      ]
    )

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ entry.id ], auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "manual" ])
    expect(results.map(&:reason)).to eq([ "Selected manually for this run" ])
  end

  it "preserves explicit manual selection order when one selected entry already matched a rule" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    automatic_entry = build_entry(id: 7)
    manual_entry = build_entry(id: 8, rules: [])

    resolver = described_class.new(
      project:,
      agent_run:,
      manual_entry_ids: [ manual_entry.id, automatic_entry.id ],
      auto_attach_enabled: true
    )
    allow(resolver).to receive(:candidate_entries).and_return([ automatic_entry, manual_entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ manual_entry, automatic_entry ])
    expect(results.map(&:source)).to eq([ "manual", "manual" ])
  end

  it "prefers team-default over automatic when the same entry matches both rule modes" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry(
      rules: [
        build_rule(mode: "automatic", enabled: true, position: 0, id: 3, rationale: "Matched automatically"),
        build_rule(mode: "team_default", enabled: true, position: 1, id: 2, rationale: "Matched as team default")
      ]
    )

    resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true, account_auto_attach_required: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "team_default" ])
    expect(results.map(&:reason)).to eq([ "Matched as team default" ])
  end

  it "memoizes persisted manual attachment ids when no manual ids were passed" do
    project = project_double
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :runner, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    resolver = described_class.new(project:, agent_run:)

    2.times { resolver.send(:effective_manual_entry_ids) }

    expect(attachments).to have_received(:where).once.with(attachment_source: "manual")
  end

  describe "rule_scoping predicates (issue_labels_includes_any, languages_include_any, repo_files_include_any)" do # @spec TOOL-SIDECAR-003 # @spec TOOL-SIDECAR-004
    let(:attachments) { agent_run_marketplace_entries }
    let(:labels_match_rule) do
      build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 11,
        rationale: "Scoped by label",
        conditions: { "issue_labels_includes_any" => [ "tooling" ] }
      )
    end
    let(:languages_match_rule) do
      build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 12,
        rationale: "Scoped by language",
        conditions: { "languages_include_any" => [ "ruby" ] }
      )
    end
    let(:repo_files_match_rule) do
      build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 13,
        rationale: "Scoped by marker file",
        conditions: { "repo_files_include_any" => [ "Gemfile" ] }
      )
    end

    it "matches an automatic rule when the issue label is in the configured set" do # @spec TOOL-SIDECAR-003
      entry = build_entry(rules: [ labels_match_rule ])
      project = project_double(repo_profile: { "languages" => [], "marker_files" => [] })
      issue = issue_double(labels: [ "tooling" ])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    it "does not match when the configured label set is non-empty but the issue carries none of the labels" do # @spec TOOL-SIDECAR-003
      entry = build_entry(rules: [ labels_match_rule ])
      project = project_double(repo_profile: { "languages" => [], "marker_files" => [] })
      issue = issue_double(labels: [ "different" ])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call).to be_empty
    end

    it "treats an absent issue_labels_includes_any key as no constraint" do # @spec TOOL-SIDECAR-003
      entry = build_entry
      project = project_double(repo_profile: { "languages" => [], "marker_files" => [] })
      issue = issue_double(labels: [ "anything" ])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    it "treats an empty issue_labels_includes_any array as no constraint" do # @spec TOOL-SIDECAR-003
      empty_labels_rule = build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 14,
        rationale: "Empty label scope",
        conditions: { "issue_labels_includes_any" => [] }
      )
      entry = build_entry(rules: [ empty_labels_rule ])
      project = project_double(repo_profile: { "languages" => [], "marker_files" => [] })
      issue = issue_double(labels: [ "anything" ])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    it "matches when the project language is in the configured set" do # @spec TOOL-SIDECAR-004
      entry = build_entry(rules: [ languages_match_rule ])
      project = project_double(repo_profile: { "languages" => [ "ruby" ], "marker_files" => [ "Gemfile" ] })
      issue = issue_double(labels: [])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    it "does not match when the project language is absent from the configured set" do # @spec TOOL-SIDECAR-004
      entry = build_entry(rules: [ languages_match_rule ])
      project = project_double(repo_profile: { "languages" => [ "javascript" ], "marker_files" => [ "package.json" ] })
      issue = issue_double(labels: [])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call).to be_empty
    end

    it "matches when the project's marker_files include the configured entry" do # @spec TOOL-SIDECAR-004
      entry = build_entry(rules: [ repo_files_match_rule ])
      project = project_double(repo_profile: { "languages" => [ "ruby" ], "marker_files" => [ "Gemfile" ] })
      issue = issue_double(labels: [])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    it "does not match when the repo profile lacks the configured marker file" do # @spec TOOL-SIDECAR-004
      entry = build_entry(rules: [ repo_files_match_rule ])
      project = project_double(repo_profile: { "languages" => [ "ruby" ], "marker_files" => [ "package.json" ] })
      issue = issue_double(labels: [])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call).to be_empty
    end

    it "does not match when the label matches but the language condition does not" do # @spec TOOL-SIDECAR-003 # @spec TOOL-SIDECAR-004
      conjunctive_rule = build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 16,
        rationale: "Label and language scope",
        conditions: { "issue_labels_includes_any" => [ "tooling" ], "languages_include_any" => [ "ruby" ] }
      )
      entry = build_entry(rules: [ conjunctive_rule ])
      project = project_double(repo_profile: { "languages" => [ "javascript" ], "marker_files" => [] })
      issue = issue_double(labels: [ "tooling" ])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call).to be_empty
    end

    it "treats an empty repo_files_include_any array as no constraint" do # @spec TOOL-SIDECAR-004
      empty_files_rule = build_rule(
        mode: "automatic",
        enabled: true,
        position: 0,
        id: 15,
        rationale: "Empty file scope",
        conditions: { "repo_files_include_any" => [] }
      )
      entry = build_entry(rules: [ empty_files_rule ])
      project = project_double(repo_profile: { "languages" => [], "marker_files" => [] })
      issue = issue_double(labels: [])
      agent_run = agent_run_for(project:, issue:)

      resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
      allow(resolver).to receive(:candidate_entries).and_return([ entry ])

      expect(resolver.call.map(&:entry)).to eq([ entry ])
    end

    def issue_double(labels:)
      Class.new do
        def initialize(labels)
          @labels = labels
        end

        attr_reader :labels
        def title = nil
        def body = nil
      end.new(labels)
    end

    def agent_run_for(project:, issue: nil)
      attachments_for_run = attachments
      issue_obj = issue
      Class.new do
        define_method(:agent_type) { "codex" }
        define_method(:goal) { "create_pr" }
        define_method(:custom_prompt) { "Implement the issue" }
        define_method(:issue) { issue_obj }
        define_method(:agent_run_marketplace_entries) { attachments_for_run }
        define_method(:runner) { nil }
      end.new
    end
  end

  def project_double(repo_profile: {})
    Class.new do
      def initialize(repo_profile)
        @repo_profile = repo_profile
      end

      def account_id = 44
      def id = 12
      def full_name = "acme/repo"
      def effective_repo_profile = @repo_profile
    end.new(repo_profile)
  end

  def agent_run_marketplace_entries
    stub_const("ResolverDblessAttachments", Class.new do
      def where(...)
      end

      def ordered
      end

      def pluck(...)
      end
    end)

    instance_double(ResolverDblessAttachments).tap do |attachments|
      allow(attachments).to receive(:where).with(attachment_source: "manual").and_return(attachments)
      allow(attachments).to receive(:ordered).and_return(attachments)
      allow(attachments).to receive(:pluck).with(:marketplace_entry_id).and_return([])
    end
  end

  def agent_run_marketplace_entries_with_manual
    stub_const("ResolverDblessManualAttachments", Class.new do
      def where(...)
      end

      def ordered
      end

      def pluck(...)
      end
    end)

    manual_relation = instance_double(ResolverDblessManualAttachments)
    allow(manual_relation).to receive(:ordered).and_return(manual_relation)
    allow(manual_relation).to receive(:pluck).with(:marketplace_entry_id).and_return([ 7 ])
    instance_double(ResolverDblessManualAttachments).tap do |attachments|
      allow(attachments).to receive(:where).with(attachment_source: "manual").and_return(manual_relation)
    end
  end

  def build_entry(id: 7, rules: default_rules)
    version_struct = Struct.new(:compatibility_constraints, keyword_init: true)
    entry_struct = Struct.new(:id, :current_version, :marketplace_entry_rules, keyword_init: true)

    stub_const("ResolverDblessRuleAssociation", Class.new do
      def select(...)
      end

      def enabled
      end

      def ordered
      end
    end)

    association = instance_double(ResolverDblessRuleAssociation)
    allow(association).to receive(:select).with(no_args).and_return(rules.select(&:enabled?))
    allow(association).to receive(:enabled).and_raise("should use the preloaded association")
    allow(association).to receive(:ordered).and_raise("should use the preloaded association")

    entry_struct.new(
      id: id,
      current_version: version_struct.new(compatibility_constraints: {}),
      marketplace_entry_rules: association
    )
  end

  def default_rules
    [
      build_rule(mode: "automatic", enabled: false, position: 0, id: 9, rationale: nil),
      build_rule(mode: "automatic", enabled: true, position: 1, id: 2, rationale: "Matched automatically")
    ]
  end

  def build_rule(mode:, enabled:, position:, id:, rationale:, conditions: {})
    Struct.new(:mode, :enabled, :position, :id, :rationale, :conditions, keyword_init: true) do
      def enabled? = enabled
    end.new(mode:, enabled:, position:, id:, rationale:, conditions: conditions)
  end
end
