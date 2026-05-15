# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Resolver, :no_db do
  it "uses the preloaded rule collection instead of relation scopes" do
    project = Struct.new(:id, :full_name).new(12, "acme/repo")
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :provider, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:, auto_attach_enabled: true)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:entry)).to eq([ entry ])
    expect(results.map(&:source)).to eq([ "automatic" ])
    expect(results.map(&:reason)).to eq([ "Matched automatically" ])
  end

  it "does not auto-attach without opt-in" do
    project = Struct.new(:id, :full_name).new(12, "acme/repo")
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :provider, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:)
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results).to be_empty
  end

  it "does not opt in to automatic or team-default entries just because a manual entry is attached" do
    project = Struct.new(:id, :full_name).new(12, "acme/repo")
    attachments = agent_run_marketplace_entries_with_manual
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :provider, :agent_run_marketplace_entries)
      .new("codex", "create_pr", "Implement the issue", nil, nil, attachments)

    entry = build_entry

    resolver = described_class.new(project:, agent_run:, manual_entry_ids: [ entry.id ])
    allow(resolver).to receive(:candidate_entries).and_return([ entry ])

    results = resolver.call

    expect(results.map(&:source)).to eq([ "manual" ])
  end

  it "applies attachment precedence as automatic < team_default < manual" do
    project = Struct.new(:id, :full_name).new(12, "acme/repo")
    attachments = agent_run_marketplace_entries
    agent_run = Struct.new(:agent_type, :goal, :custom_prompt, :issue, :provider, :agent_run_marketplace_entries)
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

  def agent_run_marketplace_entries
    stub_const("ResolverDblessAttachments", Class.new do
      def where(...)
      end

      def pluck(...)
      end
    end)

    instance_double(ResolverDblessAttachments).tap do |attachments|
      allow(attachments).to receive(:where).with(attachment_source: "manual").and_return(attachments)
      allow(attachments).to receive(:pluck).with(:marketplace_entry_id).and_return([])
    end
  end

  def agent_run_marketplace_entries_with_manual
    stub_const("ResolverDblessManualAttachments", Class.new do
      def where(...)
      end

      def pluck(...)
      end
    end)

    manual_relation = instance_double(ResolverDblessManualAttachments)
    allow(manual_relation).to receive(:pluck).with(:marketplace_entry_id).and_return([ 7 ])
    instance_double(ResolverDblessManualAttachments).tap do |attachments|
      allow(attachments).to receive(:where).with(attachment_source: "manual").and_return(manual_relation)
    end
  end

  def build_entry(rules: default_rules)
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
      id: 7,
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

  def build_rule(mode:, enabled:, position:, id:, rationale:)
    Struct.new(:mode, :enabled, :position, :id, :rationale, :conditions, keyword_init: true) do
      def enabled? = enabled
    end.new(mode:, enabled:, position:, id:, rationale:, conditions: {})
  end
end
