# frozen_string_literal: true

require "rails_helper"
require "temporalio/client"

RSpec.describe Project do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:github_token).optional }
    it { is_expected.to belong_to(:github_installation).optional }
    it { is_expected.to belong_to(:git_push_fallback_token).class_name("GithubToken").optional }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
    it { is_expected.to have_many(:project_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:members).through(:project_memberships).source(:user) }
    it { is_expected.to have_many(:issues).dependent(:destroy) }
    it { is_expected.to have_many(:agent_runs).dependent(:destroy) }
    it { is_expected.to have_many(:style_guide_ab_tests).through(:account) }
    it { is_expected.to have_many(:orchestration_decisions).dependent(:destroy) }
    it { is_expected.to have_many(:scaling_observations).dependent(:destroy) }
    it { is_expected.to have_many(:scaling_experiments).dependent(:destroy) }
    it { is_expected.to have_many(:scaling_experiment_assignments).dependent(:destroy) }
    it { is_expected.to have_many(:workflow_states).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:project) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:owner) }
    it { is_expected.to validate_presence_of(:repo) }
    it { is_expected.to validate_presence_of(:github_id) }
    it { is_expected.to validate_uniqueness_of(:github_id).scoped_to(:account_id) }
    it { is_expected.to validate_numericality_of(:poll_interval_seconds).is_greater_than_or_equal_to(60) }
    it { is_expected.to validate_numericality_of(:max_tokens_per_run).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(2_147_483_647).allow_nil }
    it { is_expected.to validate_numericality_of(:token_limit_warning_threshold).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(100) }
    it { is_expected.to validate_numericality_of(:max_execution_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(86_400) }
    it { is_expected.to validate_inclusion_of(:data_classification).in_array(described_class::DATA_CLASSIFICATIONS) }
    it { is_expected.to validate_inclusion_of(:tdd_mode).in_array(described_class::TDD_MODES) }

    it "defaults max_execution_seconds to 7200" do
      project = build(:project)
      expect(project.max_execution_seconds).to eq(7200)
    end

    it "defaults data_classification to internal" do
      project = build(:project)

      expect(project.data_classification).to eq("internal")
    end

    it "defaults tdd_mode to off" do # @spec TDD-MODE-001
      project = build(:project)

      expect(project.tdd_mode).to eq("off")
    end

    it "accepts each value in Project::TDD_MODES" do # @spec TDD-MODE-002
      described_class::TDD_MODES.each do |mode|
        project = build(:project, tdd_mode: mode)
        expect(project).to be_valid, "expected tdd_mode=#{mode.inspect} to be valid"
      end
    end

    it "rejects an unknown tdd_mode value" do # @spec TDD-MODE-002
      project = build(:project, tdd_mode: "maybe")

      expect(project).not_to be_valid
      expect(project.errors[:tdd_mode]).to be_present
    end

    it "rejects a nil tdd_mode" do # @spec TDD-MODE-002
      project = build(:project, tdd_mode: nil)

      expect(project).not_to be_valid
      expect(project.errors[:tdd_mode]).to be_present
    end

    it "persists tdd_mode and reads it back unchanged" do # @spec TDD-MODE-001
      project = create(:project, tdd_mode: "strict")
      reloaded = described_class.find(project.id)

      expect(reloaded.tdd_mode).to eq("strict")
    end

    it "validates knowledge_status inclusion" do
      project = build(:project)
      project.knowledge_status = "invalid"
      expect(project).not_to be_valid
      expect(project.errors[:knowledge_status]).to be_present
    end

    it "defaults knowledge_status to pending" do
      project = build(:project)
      expect(project.knowledge_status).to eq("pending")
    end

    # @spec PR-ESCALATION-024
    it "defaults the approval-wait escalation ceiling to one day" do
      expect(build(:project).pr_approval_escalation_hours).to eq(24)
    end

    # @spec PR-ESCALATION-024
    it "rejects a negative approval-wait escalation ceiling" do
      project = build(:project)
      project.pr_approval_escalation_hours = -1

      expect(project).not_to be_valid
      expect(project.errors[:pr_approval_escalation_hours]).to be_present
    end

    describe "github_token account validation" do
      it "allows github_token from the same account" do
        account = create(:account)
        github_token = create(:github_token, account: account)
        project = build(:project, account: account, github_token: github_token)

        expect(project).to be_valid
      end

      it "rejects github_token from a different account" do
        account = create(:account)
        other_account = create(:account)
        github_token = create(:github_token, account: other_account)
        project = build(:project, account: account, github_token: github_token)

        expect(project).not_to be_valid
        expect(project.errors[:github_token]).to include("must belong to the same account")
      end
    end

    describe "git_push_fallback_token validation" do
      it "allows a fallback token from the same account on an app-backed project" do
        account = create(:account)
        fallback = create(:github_token, :with_workflow_scope, account: account)
        project = build(:project, :with_github_installation, account: account, git_push_fallback_token: fallback)

        expect(project).to be_valid
      end

      it "rejects a fallback token from a different account" do
        account = create(:account)
        fallback = create(:github_token, account: create(:account))
        project = build(:project, :with_github_installation, account: account, git_push_fallback_token: fallback)

        expect(project).not_to be_valid
        expect(project.errors[:git_push_fallback_token]).to include("must belong to the same account")
      end

      it "clears the fallback config when the project is not app-backed (no dead-end on auth switch)" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = build(:project, account: account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project).to be_valid
        expect(project.git_push_fallback_token_id).to be_nil
        expect(project.git_push_pat_fallback_enabled).to be(false)
      end

      it "rejects a non-existent fallback token id on an app-backed project" do
        account = create(:account)
        project = build(:project, :with_github_installation, account: account)
        project.git_push_fallback_token_id = 0

        expect(project).not_to be_valid
        expect(project.errors[:git_push_fallback_token]).to include("must belong to the same account")
      end

      it "rejects enabling the fallback without selecting a token" do
        account = create(:account)
        project = build(:project, :with_github_installation, account: account, git_push_pat_fallback_enabled: true)

        expect(project).not_to be_valid
        expect(project.errors[:git_push_fallback_token]).to include("must be selected to enable PAT push fallback")
      end

      it "allows enabling the fallback with a same-account token on an app-backed project" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = build(:project, :with_github_installation, account: account,
          git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project).to be_valid
      end
    end

    describe "created_by account validation" do
      it "allows created_by from the same account" do
        account = create(:account)
        user = create(:user, account: account)
        project = build(:project, account: account, created_by: user)

        expect(project).to be_valid
      end

      it "rejects created_by from a different account" do
        account = create(:account)
        other_account = create(:account)
        user = create(:user, account: other_account)
        project = build(:project, account: account, created_by: user)

        expect(project).not_to be_valid
        expect(project.errors[:created_by]).to include("must belong to the same account")
      end

      it "allows nil created_by" do
        project = build(:project, :without_creator)

        expect(project).to be_valid
      end
    end

    describe "interop settings validation" do
      it "accepts supported adoption modes and source maps" do
        project = build(:project, interop_settings: {
          "adoption_mode" => "review_only",
          "tool_integrations" => { "cursor" => true },
          "connectors" => { "slack" => true },
          "external_execution_sources" => { "github_copilot" => true },
          "imports" => { "prompts" => [ { "source_identifier" => "prompt-1" } ] }
        })

        expect(project).to be_valid
      end

      it "rejects unknown adoption modes" do
        project = build(:project, interop_settings: { "adoption_mode" => "shadow" })

        expect(project).not_to be_valid
        expect(project.errors[:interop_settings].join).to include("adoption_mode")
      end

      it "rejects unknown external execution sources" do
        project = build(:project, interop_settings: {
          "external_execution_sources" => { "unknown_tool" => true }
        })

        expect(project).not_to be_valid
        expect(project.errors[:interop_settings].join).to include("unknown entries")
      end
    end

    describe "preferred docker host validation" do
      it "rejects a preferred host identifier that is not enabled for the account" do
        account = create(:account)
        create(:docker_host, account: account, identifier: "disabled-host", enabled: false)
        project = build(:project, account: account, preferred_docker_host_identifier: "disabled-host")

        expect(project).not_to be_valid
        expect(project.errors[:preferred_docker_host_identifier]).to include("must reference an enabled Docker host")
      end
    end

    describe "LLM provider routing validation" do
      it "accepts an allowlist of supported provider keys" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "anthropic" ] } })

        expect(project).to be_valid
      end

      it "accepts a blocklist of supported provider keys" do
        project = build(:project, model_preferences: { "llm_providers" => { "blocklist" => [ "openai", "google" ] } })

        expect(project).to be_valid
      end

      it "rejects specifying both allowlist and blocklist" do
        project = build(:project, model_preferences: {
          "llm_providers" => { "allowlist" => [ "anthropic" ], "blocklist" => [ "openai" ] }
        })

        expect(project).not_to be_valid
        expect(project.errors[:model_preferences].join).to include("mutually exclusive")
      end

      it "rejects unknown provider identifiers in the allowlist" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "bogus" ] } })

        expect(project).not_to be_valid
        expect(project.errors[:model_preferences].join).to include("unknown provider")
      end

      it "rejects an allowlist that is not an array" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => "anthropic" } })

        expect(project).not_to be_valid
        expect(project.errors[:model_preferences].join).to include("must be an array")
      end

      it "rejects a non-object llm_providers value" do
        project = build(:project, model_preferences: { "llm_providers" => [ "anthropic" ] })

        expect(project).not_to be_valid
        expect(project.errors[:model_preferences].join).to include("must be a JSON object")
      end

      it "normalizes, dedupes, and sorts the configured lists before validation" do
        project = build(:project, model_preferences: {
          "llm_providers" => { "allowlist" => [ "Google", "anthropic ", "google" ] }
        })

        project.valid?

        expect(project.model_preferences["llm_providers"]["allowlist"]).to eq(%w[anthropic google])
      end

      it "treats empty lists as no restriction and remains valid" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [], "blocklist" => [] } })

        expect(project).to be_valid
        expect(project.llm_provider_routing_restricted?).to be(false)
      end

      it "does not affect projects without llm_providers configuration" do
        project = build(:project, model_preferences: { "required_model_id" => "claude-sonnet-4-6" })

        expect(project).to be_valid
        expect(project.llm_provider_routing_restricted?).to be(false)
      end
    end
  end

  describe "#detected_language" do
    it "normalizes the primary language" do
      project = build(:project)
      project.define_singleton_method(:primary_language) { " Ruby " }

      expect(project.detected_language).to eq("ruby")
    end

    it "returns nil when the primary language is blank" do
      project = build(:project)
      project.define_singleton_method(:primary_language) { " " }

      expect(project.detected_language).to be_nil
    end
  end

  describe "#project_type_label" do
    it "returns a friendly label when the language profile knows it" do
      project = build(:project)
      project.define_singleton_method(:primary_language) { "Ruby" }

      expect(project.project_type_label).to eq("Ruby on Rails")
    end

    it "prefers the detected framework label when screenshot detection metadata exists" do
      project = build(:project, screenshot_settings: {
        "detection" => { "framework" => "Phoenix" }
      })
      project.define_singleton_method(:primary_language) { "Ruby" }

      expect(project.project_type_label).to eq("Phoenix")
    end

    it "falls back to the primary language when no profile label exists" do
      allow(Projects::LanguageProfile).to receive(:label_for).with("Elixir").and_return(nil)
      project = build(:project)
      project.define_singleton_method(:primary_language) { "Elixir" }

      expect(project.project_type_label).to eq("Elixir")
    end
  end

  describe "LLM provider allowlist/blocklist" do
    describe "#llm_provider_routing" do
      it "returns empty lists when no routing is configured" do
        project = build(:project)

        expect(project.llm_provider_routing).to eq("allowlist" => [], "blocklist" => [])
      end

      it "reads the configured allowlist and blocklist" do
        project = build(:project, model_preferences: { "llm_providers" => { "blocklist" => [ "openai" ] } })

        expect(project.llm_provider_allowlist).to eq([])
        expect(project.llm_provider_blocklist).to eq(%w[openai])
      end

      it "coerces non-string entries to strings" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ :anthropic ] } })

        expect(project.llm_provider_allowlist).to eq(%w[anthropic])
      end
    end

    describe "#llm_provider_routing_mode" do
      it "returns nil when unrestricted" do
        expect(build(:project).llm_provider_routing_mode).to be_nil
      end

      it "returns allowlist/blocklist mode" do
        allowlist_project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "anthropic" ] } })
        blocklist_project = build(:project, model_preferences: { "llm_providers" => { "blocklist" => [ "openai" ] } })

        expect(allowlist_project.llm_provider_routing_mode).to eq("allowlist")
        expect(blocklist_project.llm_provider_routing_mode).to eq("blocklist")
      end
    end

    describe "#llm_provider_allowed?" do
      it "permits every provider when unrestricted" do
        project = build(:project)

        expect(project.llm_provider_allowed?("anthropic")).to be(true)
        expect(project.llm_provider_allowed?("openai")).to be(true)
        expect(project.llm_provider_allowed?(nil)).to be(true)
      end

      it "only permits allowlisted providers" do
        project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "anthropic" ] } })

        expect(project.llm_provider_allowed?("anthropic")).to be(true)
        expect(project.llm_provider_allowed?("openai")).to be(false)
        expect(project.llm_provider_blocked?("openai")).to be(true)
      end

      it "blocks only blocklisted providers" do
        project = build(:project, model_preferences: { "llm_providers" => { "blocklist" => [ "openai", "google" ] } })

        expect(project.llm_provider_allowed?("anthropic")).to be(true)
        expect(project.llm_provider_blocked?("openai")).to be(true)
        expect(project.llm_provider_blocked?("google")).to be(true)
      end

      it "validates against the supported provider key catalog" do
        expect(described_class.supported_llm_provider_keys).to include("anthropic", "openai", "google")
      end
    end
  end

  describe "scopes" do
    describe ".active" do
      it "includes active projects" do
        active_project = create(:project, active: true)
        expect(described_class.active).to include(active_project)
      end

      it "excludes inactive projects" do
        inactive_project = create(:project, :inactive)
        expect(described_class.active).not_to include(inactive_project)
      end
    end

    describe ".inactive" do
      it "includes inactive projects" do
        inactive_project = create(:project, :inactive)
        expect(described_class.inactive).to include(inactive_project)
      end

      it "excludes active projects" do
        active_project = create(:project, active: true)
        expect(described_class.inactive).not_to include(active_project)
      end
    end
  end

  describe "instance methods" do
    describe "#full_name" do
      it "returns owner/repo format" do
        project = build(:project, owner: "viamin", repo: "paid")
        expect(project.full_name).to eq("viamin/paid")
      end
    end

    describe "#detected_language" do
      it "returns the downcased primary language" do
        project = build(:project, primary_language: "Ruby")
        expect(project.detected_language).to eq("ruby")
      end

      it "normalizes surrounding whitespace and casing" do
        project = build(:project, primary_language: "  TypeScript  ")
        expect(project.detected_language).to eq("typescript")
      end

      it "returns nil when no language is set" do
        expect(build(:project, primary_language: nil).detected_language).to be_nil
      end
    end

    describe "#detected_framework" do
      it "prefers the persisted repo profile framework" do
        project = build(:project,
          repo_profile: { "framework" => "phoenix" },
          screenshot_settings: { "detection" => { "framework" => "Next.js" } })

        expect(project.detected_framework).to eq("phoenix")
      end

      it "normalizes persisted screenshot detection metadata" do
        project = build(:project, screenshot_settings: {
          "detection" => { "framework" => "Next.js" }
        })

        expect(project.detected_framework).to eq("nextjs")
      end

      it "returns nil when no framework is set" do
        expect(build(:project).detected_framework).to be_nil
      end
    end

    describe "#detected_languages" do
      it "returns the persisted repo languages" do
        project = build(:project, repo_profile: { "languages" => %w[ruby javascript] })

        expect(project.detected_languages).to eq(%w[ruby javascript])
      end

      it "falls back to the primary language" do
        expect(build(:project, primary_language: "Ruby").detected_languages).to eq(%w[ruby])
      end
    end

    describe "#test_languages" do
      it "returns persisted test languages when present" do
        project = build(:project, repo_profile: {
          "languages" => %w[elixir javascript],
          "test_languages" => %w[elixir]
        })

        expect(project.test_languages).to eq(%w[elixir])
      end

      it "falls back to detected languages" do
        project = build(:project, repo_profile: { "languages" => %w[ruby javascript] })

        expect(project.test_languages).to eq(%w[ruby javascript])
      end
    end

    describe "#detected_framework_label" do
      it "returns the human-friendly framework label" do
        project = build(:project, screenshot_settings: {
          "detection" => { "framework" => "phoenix" }
        })

        expect(project.detected_framework_label).to eq("Phoenix")
      end

      it "returns nil when no framework is set" do
        expect(build(:project).detected_framework_label).to be_nil
      end
    end

    describe "#project_type_label" do
      it "maps known languages to a framework label" do
        expect(build(:project, primary_language: "Ruby").project_type_label).to eq("Ruby on Rails")
        expect(build(:project, primary_language: "Elixir").project_type_label).to eq("Phoenix / Elixir")
        expect(build(:project, primary_language: "Swift").project_type_label).to eq("macOS / Swift")
      end

      it "is case-insensitive" do
        expect(build(:project, primary_language: "elixir").project_type_label).to eq("Phoenix / Elixir")
      end

      it "falls back to the raw language when unmapped" do
        expect(build(:project, primary_language: "Brainfuck").project_type_label).to eq("Brainfuck")
      end

      it "prefers the detected framework label when available" do
        project = build(:project,
          primary_language: "Ruby",
          screenshot_settings: { "detection" => { "framework" => "Phoenix" } })

        expect(project.project_type_label).to eq("Phoenix")
      end

      it "returns nil when no language is set" do
        expect(build(:project, primary_language: nil).project_type_label).to be_nil
      end
    end

    describe "#github_url" do
      it "returns the GitHub URL" do
        project = build(:project, owner: "viamin", repo: "paid")
        expect(project.github_url).to eq("https://github.com/viamin/paid")
      end
    end

    describe "#confidential?" do
      it "returns true for confidential projects" do
        expect(build(:project, data_classification: "confidential")).to be_confidential
      end

      it "returns false for other classifications" do
        expect(build(:project, data_classification: "internal")).not_to be_confidential
      end
    end

    describe "#restricted?" do
      it "returns true for restricted projects" do
        expect(build(:project, data_classification: "restricted")).to be_restricted
      end

      it "returns false for other classifications" do
        expect(build(:project, data_classification: "confidential")).not_to be_restricted
      end
    end

    describe "#tdd_mode_label" do # @spec TDD-MODE-005
      it "returns the human-readable label for each supported mode" do
        Project::TDD_MODES.each do |mode|
          expect(build(:project, tdd_mode: mode).tdd_mode_label).to eq(Project::TDD_MODE_LABELS[mode])
        end
      end

      it "falls back to titleizing the raw value when the mode is unknown" do
        project = build(:project)
        project.tdd_mode = "experimental"

        expect(project.tdd_mode_label).to eq("Experimental")
      end
    end

    describe "#header_external_links" do
      it "returns a single GitHub link when GitHub handles both repo and issues" do
        project = build(:project, owner: "viamin", repo: "paid")
        tracker_configuration = build(:tracker_configuration, configurable: project, tracker_type: "github_issues")

        expect(project.header_external_links(tracker_configuration: tracker_configuration)).to eq([
          { label: "GitHub", url: "https://github.com/viamin/paid" }
        ])
      end

      it "returns separate repository and issue tracker links when the tracker is external" do
        project = build(:project, owner: "viamin", repo: "paid")
        tracker_configuration = build(:tracker_configuration, :linear, configurable: project)

        expect(project.header_external_links(tracker_configuration: tracker_configuration)).to eq([
          { label: "GitHub Repo", url: "https://github.com/viamin/paid" },
          { label: "Linear Issues", url: "https://linear.app" }
        ])
      end
    end

    describe "#activate!" do
      it "sets active to true" do
        project = create(:project, :inactive)
        project.activate!

        expect(project.active).to be true
      end
    end

    describe "#deactivate!" do
      it "sets active to false" do
        project = create(:project)
        project.deactivate!

        expect(project.active).to be false
      end
    end

    describe "#label_for_stage" do
      it "returns the label for the given stage" do
        project = build(:project, :with_label_mappings)

        expect(project.label_for_stage(:planning)).to eq("paid:planning")
        expect(project.label_for_stage("in_progress")).to eq("paid:in-progress")
      end

      it "returns nil for unknown stage" do
        project = build(:project)

        expect(project.label_for_stage(:unknown)).to be_nil
      end
    end

    describe "#set_label_for_stage" do
      it "sets the label for the given stage" do
        project = build(:project)
        project.set_label_for_stage(:planning, "custom:planning")

        expect(project.label_mappings["planning"]).to eq("custom:planning")
      end

      it "preserves existing label mappings" do
        project = build(:project, :with_label_mappings)
        project.set_label_for_stage(:new_stage, "custom:new")

        expect(project.label_mappings["planning"]).to eq("paid:planning")
        expect(project.label_mappings["new_stage"]).to eq("custom:new")
      end
    end

    describe "#priority_label_for" do
      it "returns the configured label name for a tier" do
        project = build(:project, priority_labels: { "P1" => "critical", "P2" => "high", "P3" => "low" })
        expect(project.priority_label_for("P1")).to eq("critical")
        expect(project.priority_label_for(:P2)).to eq("high")
      end

      it "falls back to defaults when priority_labels is empty" do
        project = build(:project, priority_labels: {})
        expect(project.priority_label_for("P1")).to eq("P1")
      end

      it "treats a null mapping value as unset and falls back to the default" do
        project = build(:project, priority_labels: { "P1" => nil, "P2" => "high" })
        expect(project.priority_label_for("P1")).to eq("P1")
        expect(project.priority_label_for("P2")).to eq("high")
      end
    end

    describe "priority_labels validation" do
      it "rejects unknown keys" do
        project = build(:project, priority_labels: { "P1" => "critical", "P9" => "ultra" })
        expect(project).not_to be_valid
        expect(project.errors[:priority_labels].join).to include('may only contain keys')
      end

      it "rejects blank string values" do
        project = build(:project, priority_labels: { "P1" => "  " })
        expect(project).not_to be_valid
        expect(project.errors[:priority_labels].join).to include('non-blank string')
      end

      it "accepts valid hash" do
        project = build(:project, priority_labels: { "P1" => "critical", "P2" => "high", "P3" => "low" })
        expect(project).to be_valid
      end

      it "trims surrounding whitespace from values on save" do
        project = build(:project, priority_labels: { "P1" => "  critical  ", "P2" => "high", "P3" => "low" })
        expect(project).to be_valid
        expect(project.priority_labels["P1"]).to eq("critical")
      end
    end

    describe "#project_level_max_tokens_per_run" do
      it "returns the project override when set" do
        project = build(:project, max_tokens_per_run: 500_000)
        expect(project.project_level_max_tokens_per_run).to eq(500_000)
      end

      it "falls back to account default when project override is nil" do
        project = create(:project, max_tokens_per_run: nil)
        project.account.update!(default_max_tokens_per_run: 2_000_000)
        expect(project.project_level_max_tokens_per_run).to eq(2_000_000)
      end
    end

    describe "#adoption_mode" do
      it "falls back to observe_only" do
        expect(build(:project).adoption_mode).to eq("observe_only")
      end

      it "returns the configured mode" do
        project = build(:project, :with_interop_settings)
        expect(project.adoption_mode).to eq("advisory")
        expect(project).to be_advisory
      end
    end

    describe "#external_execution_enabled_for?" do
      it "checks the defaults-merged external execution sources" do
        project = build(:project, :with_interop_settings)

        expect(project.external_execution_enabled_for?(:cursor)).to be(true)
        expect(project.external_execution_enabled_for?(:devin)).to be(false)
      end
    end

    describe "#token_limit_warning_at" do
      it "returns 80% of the effective limit by default" do
        project = build(:project, max_tokens_per_run: 1_000_000)
        expect(project.token_limit_warning_at).to eq(800_000)
      end

      it "respects a custom warning threshold" do
        project = build(:project, max_tokens_per_run: 1_000_000, token_limit_warning_threshold: 90)
        expect(project.token_limit_warning_at).to eq(900_000)
      end
    end

    describe "#increment_metrics!" do
      it "increments cost and tokens used" do
        project = create(:project, total_cost_cents: 100, total_tokens_used: 1000)

        project.increment_metrics!(cost_cents: 50, tokens_used: 500)

        expect(project.total_cost_cents).to eq(150)
        expect(project.total_tokens_used).to eq(1500)
      end
    end
  end

  describe "polling lifecycle hooks" do
    let(:temporal_client) { instance_double(Temporalio::Client) }
    let(:workflow_handle) { double("workflow_handle") } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(Paid).to receive_messages(temporal_client: temporal_client, poll_task_queue: "paid-poll-tasks")
      allow(temporal_client).to receive(:start_workflow)
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:cancel)
    end

    describe "after_create_commit" do
      it "starts polling for active projects" do
        project = create(:project, active: true)

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::GitHubPollWorkflow,
          { project_id: project.id },
          id: "github-poll-#{project.id}",
          task_queue: "paid-poll-tasks"
        )
      end

      it "does not start polling for inactive projects" do
        create(:project, :inactive)

        expect(temporal_client).not_to have_received(:start_workflow)
      end

      it "enqueues EnqueueKnowledgeCollectionJob" do
        expect {
          create(:project)
        }.to have_enqueued_job(EnqueueKnowledgeCollectionJob)
      end

      it "logs error when knowledge collection enqueue fails" do
        allow(EnqueueKnowledgeCollectionJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
        allow(Rails.logger).to receive(:error)

        project = create(:project)

        expect(Rails.logger).to have_received(:error).with(
          hash_including(message: "knowledge.enqueue_collection_failed", project_id: project.id)
        )
      end
    end

    describe "after_destroy_commit" do
      it "stops polling when project is destroyed" do
        project = create(:project, active: true)

        project.destroy!

        expect(temporal_client).to have_received(:workflow_handle).with("github-poll-#{project.id}")
        expect(workflow_handle).to have_received(:cancel)
      end

      it "does not stop polling when destroy is rolled back" do
        project = create(:project, active: true)

        expect {
          ActiveRecord::Base.transaction do
            project.destroy!
            raise ActiveRecord::Rollback
          end
        }.not_to change(described_class, :count)

        expect(workflow_handle).not_to have_received(:cancel)
      end
    end

    describe "after_update_commit on active change" do
      it "starts polling when activated" do
        project = create(:project, :inactive)

        project.activate!

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::GitHubPollWorkflow,
          { project_id: project.id },
          id: "github-poll-#{project.id}",
          task_queue: "paid-poll-tasks"
        )
      end

      it "stops polling when deactivated" do
        project = create(:project, active: true)

        project.deactivate!

        expect(temporal_client).to have_received(:workflow_handle).with("github-poll-#{project.id}")
        expect(workflow_handle).to have_received(:cancel)
      end

      it "does not toggle polling when other attributes change" do
        project = create(:project, active: true)

        project.update!(name: "new-name")

        expect(workflow_handle).not_to have_received(:cancel)
        # start_workflow only called once (on create), not again on name update
        expect(temporal_client).to have_received(:start_workflow).once
      end
    end
  end

  describe "after_update_commit on auto_pick_enabled change" do
    let(:temporal_client) { instance_double(Temporalio::Client) }
    let(:workflow_handle) { double("workflow_handle", cancel: true) } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(Paid).to receive_messages(temporal_client: temporal_client, poll_task_queue: "paid-poll-tasks")
      allow(temporal_client).to receive(:start_workflow)
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(Issues::BulkEnqueueEligible).to receive(:call)
    end

    it "bulk seeds eligible issues when auto_pick is enabled" do
      project = create(:project, auto_pick_enabled: false)

      project.update!(auto_pick_enabled: true)

      expect(Issues::BulkEnqueueEligible).to have_received(:call).with(project: project, skip_project_gate: true)
    end

    it "bulk seeds even when the project has open PRs needing attention" do
      project = create(:project, auto_pick_enabled: false)
      create(:issue,
        project: project,
        is_pull_request: true,
        github_state: "open",
        paid_state: "in_progress",
        labels: [])

      project.update!(auto_pick_enabled: true)

      expect(Issues::BulkEnqueueEligible).to have_received(:call).with(project: project, skip_project_gate: true)
    end

    it "does not bulk seed when auto_pick is disabled" do
      # @spec AUTO-PICK-QUEUE-001
      project = create(:project, auto_pick_enabled: true)

      project.update!(auto_pick_enabled: false)

      expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
    end

    it "cancels queued auto-pick runs when auto_pick is disabled" do
      # @spec AUTO-PICK-QUEUE-001
      project = create(:project, auto_pick_enabled: true)
      queued_auto_pick = create(:agent_run, :queued, project: project, auto_pick: true, trigger_type: "automatic")
      claimed_auto_pick = create(:agent_run, :queued, project: project, auto_pick: true, trigger_type: "automatic", temporal_workflow_id: "claimed")
      automatic_enhance_issue = create(:agent_run, :queued, :enhance_issue_goal, project: project, auto_pick: false, trigger_type: "automatic")
      manual_enhance_issue = create(:agent_run, :queued, :enhance_issue_goal, :manual, project: project, auto_pick: false)
      running_auto_pick = create(:agent_run, :running, project: project, auto_pick: true, trigger_type: "automatic")
      manual_run = create(:agent_run, :queued, :manual, project: project, auto_pick: false)
      other_project_run = create(:agent_run, :queued, auto_pick: true, trigger_type: "automatic")

      project.update!(auto_pick_enabled: false)

      expect(queued_auto_pick.reload).to have_attributes(status: "cancelled", error_message: "Auto-Pick disabled for project")
      expect(claimed_auto_pick.reload).to have_attributes(status: "cancelled", error_message: "Auto-Pick disabled for project")
      expect(automatic_enhance_issue.reload.status).to eq("cancelled")
      expect(manual_enhance_issue.reload.status).to eq("queued")
      expect(running_auto_pick.reload.status).to eq("running")
      expect(manual_run.reload.status).to eq("queued")
      expect(other_project_run.reload.status).to eq("queued")
    end

    it "cancels the Temporal workflow of a claimed queued auto-pick run when auto_pick is disabled" do
      # @spec AUTO-PICK-QUEUE-001
      project = create(:project, auto_pick_enabled: true)
      create(:agent_run, :queued, project: project, auto_pick: true, trigger_type: "automatic", temporal_workflow_id: "claimed")

      project.update!(auto_pick_enabled: false)

      expect(temporal_client).to have_received(:workflow_handle).with("claimed")
      expect(workflow_handle).to have_received(:cancel)
    end

    it "enqueues a live dashboard broadcast for each cancelled queued auto-pick run when auto_pick is disabled" do
      # @spec AUTO-PICK-QUEUE-001
      project = create(:project, auto_pick_enabled: true)
      queued_auto_pick = create(:agent_run, :queued, project: project, auto_pick: true, trigger_type: "automatic")
      claimed_auto_pick = create(:agent_run, :queued, project: project, auto_pick: true, trigger_type: "automatic", temporal_workflow_id: "claimed")

      expect {
        project.update!(auto_pick_enabled: false)
      }.to have_enqueued_job(LiveDashboardBroadcastJob)
        .with(project.account_id, queued_auto_pick.id, refresh_queue_preview: true)
        .and have_enqueued_job(LiveDashboardBroadcastJob)
        .with(project.account_id, claimed_auto_pick.id, refresh_queue_preview: true)
    end

    it "does not bulk seed when other attributes change" do
      project = create(:project, auto_pick_enabled: true)

      project.update!(name: "new-name")

      expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
    end

    it "logs error when bulk seeding fails" do
      project = create(:project, auto_pick_enabled: false)
      allow(Issues::BulkEnqueueEligible).to receive(:call).and_raise(StandardError, "queue unavailable")
      allow(Rails.logger).to receive(:error)

      project.update!(auto_pick_enabled: true)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "auto_pick.bulk_seed_failed", project_id: project.id)
      )
    end
  end

  describe "allowed_github_usernames validation" do
    it "requires at least one trusted username" do
      project = build(:project, allowed_github_usernames: [])

      expect(project).not_to be_valid
      expect(project.errors[:allowed_github_usernames]).to include("must include at least one trusted GitHub username")
    end

    it "rejects array with only blank strings" do
      project = build(:project, allowed_github_usernames: [ "", " " ])

      expect(project).not_to be_valid
    end

    it "accepts array with at least one present username" do
      project = build(:project, allowed_github_usernames: [ "viamin" ])

      expect(project).to be_valid
    end
  end

  describe "#pr_numbers_with_queued_auto_continue" do
    let(:project) { create(:project) }

    it "returns PR numbers with queued automatic runs" do
      create(:agent_run, :queued, :automatic, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_queued_auto_continue).to eq(Set[42])
    end

    it "excludes completed automatic runs" do
      create(:agent_run, :completed, :automatic, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_queued_auto_continue).to be_empty
    end

    it "excludes queued manual runs" do
      create(:agent_run, :queued, :manual, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_queued_auto_continue).to be_empty
    end
  end

  describe "#pr_numbers_with_active_runs" do
    let(:project) { create(:project) }

    it "returns PR numbers with queued runs" do
      create(:agent_run, :queued, :manual, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_active_runs).to eq(Set[42])
    end

    it "returns PR numbers with running runs" do
      create(:agent_run, :running, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_active_runs).to eq(Set[42])
    end

    it "excludes completed runs" do
      create(:agent_run, :completed, project: project,
        source_pull_request_number: 42, custom_prompt: "Fix PR")

      expect(project.pr_numbers_with_active_runs).to be_empty
    end

    it "excludes runs without a source PR number" do
      create(:agent_run, :queued, :manual, project: project,
        source_pull_request_number: nil, custom_prompt: "Fix something")

      expect(project.pr_numbers_with_active_runs).to be_empty
    end
  end

  describe "#has_running_database_container?" do
    let(:project) { create(:project) }

    it "returns false when no service containers exist" do
      expect(project.has_running_database_container?).to be false
    end

    it "returns true when a running postgres container is associated" do
      sc = create(:service_container, :running, image: "postgres:16")
      create(:project_service_container, project: project, service_container: sc)

      expect(project.has_running_database_container?).to be true
    end

    it "returns false when postgres container is stopped" do
      sc = create(:service_container, image: "postgres:16", status: "stopped")
      create(:project_service_container, project: project, service_container: sc)

      expect(project.has_running_database_container?).to be false
    end

    it "returns false when only non-database containers are running" do
      sc = create(:service_container, :running, :redis)
      create(:project_service_container, project: project, service_container: sc)

      expect(project.has_running_database_container?).to be false
    end
  end

  describe "#trusted_github_user?" do
    let(:project) { build(:project, allowed_github_usernames: [ "viamin", "OtherUser" ]) }

    it "returns true for an allowlisted user" do
      expect(project.trusted_github_user?("viamin")).to be true
    end

    it "is case-insensitive" do
      expect(project.trusted_github_user?("VIAMIN")).to be true
      expect(project.trusted_github_user?("otheruser")).to be true
      expect(project.trusted_github_user?("OtherUser")).to be true
    end

    it "returns false for a non-allowlisted user" do
      expect(project.trusted_github_user?("attacker")).to be false
    end

    it "returns false for nil login" do
      expect(project.trusted_github_user?(nil)).to be false
    end

    it "returns false for blank login" do
      expect(project.trusted_github_user?("")).to be false
    end
  end

  describe "GitHub App bot trust" do
    let(:bot_login) { Github::AppRegistry.bot_login }

    context "with GitHub App auth" do
      let(:project) { build(:project, :with_github_installation, allowed_github_usernames: [ "viamin" ]) }

      it "trusts the app bot as an issue/PR author (case-insensitively)" do
        expect(project.trusted_github_author?(bot_login)).to be true
        expect(project.trusted_github_author?(bot_login.upcase)).to be true
        expect(project.trusted_github_author_logins).to include("viamin", bot_login.downcase)
      end

      it "does NOT author-trust the bare app slug (a registerable human username)" do
        expect(bot_login).to end_with("[bot]")
        expect(project.trusted_github_author?(Github::AppRegistry.slug)).to be false
        expect(project.trusted_github_author_logins).not_to include(Github::AppRegistry.slug.downcase)
      end

      it "does NOT trust the app bot as a comment author" do
        expect(project.trusted_github_user?(bot_login)).to be false
      end

      it "does not add dependency-update bot authors to global author trust" do
        project.auto_merge_mode = "dependabot_only"

        expect(project.trusted_github_author_logins).not_to include("dependabot[bot]", "renovate[bot]")
        expect(project.trusted_github_author?("dependabot[bot]")).to be false
        expect(project.trusted_github_user?("dependabot[bot]")).to be false
      end

      it "identifies the app bot as Paid's own author for marker re-admission" do
        expect(project.paid_bot_author?(bot_login)).to be true
        expect(project.paid_bot_author?(bot_login.upcase)).to be true
      end

      it "does not treat allowlisted humans or others as the Paid bot" do
        expect(project.paid_bot_author?("viamin")).to be false
        expect(project.paid_bot_author?("attacker")).to be false
        expect(project.paid_bot_author?(nil)).to be false
      end

      it "still trusts allowlisted humans for both comments and authorship" do
        expect(project.trusted_github_user?("viamin")).to be true
        expect(project.trusted_github_author?("viamin")).to be true
      end

      it "does not store the bot in allowed_github_usernames" do
        expect(project.allowed_github_usernames).to eq([ "viamin" ])
      end
    end

    context "with PAT auth" do
      let(:project) { build(:project, allowed_github_usernames: [ "viamin" ]) }

      it "does not trust the bot as either author or commenter" do
        expect(project.trusted_github_author?(bot_login)).to be false
        expect(project.trusted_github_user?(bot_login)).to be false
      end

      it "has no Paid bot identity to re-admit (returns false)" do
        expect(project.paid_bot_author?(bot_login)).to be false
      end
    end

    context "with Dependabot auto-merge enabled" do
      let(:project) do
        build(:project, :with_github_installation,
          allowed_github_usernames: [ "viamin" ],
          auto_merge_mode: "dependabot_only")
      end

      it "does NOT trust dependabot as a global author" do
        expect(project.trusted_github_author?("dependabot[bot]")).to be false
        expect(project.trusted_github_author?("renovate[bot]")).to be false
        expect(project.trusted_github_author?("dependabot-preview[bot]")).to be false
      end

      it "does NOT trust dependabot as a comment author (prevents prompt injection)" do
        expect(project.trusted_github_user?("dependabot[bot]")).to be false
      end

      it "still trusts allowlisted humans for both comments and authorship" do
        expect(project.trusted_github_author?("viamin")).to be true
        expect(project.trusted_github_user?("viamin")).to be true
      end

      context "when auto_merge_mode is 'all'" do
        let(:project) do
          build(:project, :with_github_installation,
            allowed_github_usernames: [ "viamin" ],
            auto_merge_mode: "all")
        end

        it "still does not trust dependabot as a global author" do
          expect(project.trusted_github_author?("dependabot[bot]")).to be false
        end
      end
    end

    context "with Dependabot auto-merge disabled" do
      let(:project) do
        build(:project, :with_github_installation,
          allowed_github_usernames: [ "viamin" ],
          auto_merge_mode: "off")
      end

      it "does not trust dependabot as an author" do
        expect(project.trusted_github_author?("dependabot[bot]")).to be false
      end
    end
  end

  describe ".ransackable_attributes" do
    it "returns the allowed sortable attributes" do
      expect(described_class.ransackable_attributes).to contain_exactly(
        "name", "last_agent_run_at", "last_github_activity_at", "created_at"
      )
    end
  end

  describe ".ransackable_associations" do
    it "returns an empty array" do
      expect(described_class.ransackable_associations).to eq([])
    end
  end

  describe "#touch_last_agent_run_at" do
    it "updates the last_agent_run_at column" do
      project = create(:project)
      timestamp = 1.hour.ago

      project.touch_last_agent_run_at(timestamp)

      expect(project.reload.last_agent_run_at).to be_within(1.second).of(timestamp)
    end
  end

  describe "#touch_last_github_activity_at" do
    it "updates the last_github_activity_at column" do
      project = create(:project)
      timestamp = 2.hours.ago

      project.touch_last_github_activity_at(timestamp)

      expect(project.reload.last_github_activity_at).to be_within(1.second).of(timestamp)
    end
  end

  describe "#touch_last_polled_at" do
    it "updates the last_polled_at column" do
      project = create(:project)
      timestamp = 30.minutes.ago

      project.touch_last_polled_at(timestamp)

      expect(project.reload.last_polled_at).to be_within(1.second).of(timestamp)
    end

    it "defaults to current time" do
      project = create(:project)

      freeze_time do
        project.touch_last_polled_at

        expect(project.reload.last_polled_at).to eq(Time.current)
      end
    end
  end

  describe "label_mappings JSONB storage" do
    it "stores label mappings as JSONB" do
      mappings = {
        "planning" => "paid:planning",
        "in_progress" => "paid:in-progress"
      }
      project = create(:project, label_mappings: mappings)
      reloaded = described_class.find(project.id)

      expect(reloaded.label_mappings).to eq(mappings)
    end

    it "defaults to empty hash" do
      project = create(:project, label_mappings: {})
      expect(project.label_mappings).to eq({})
    end
  end

  describe "review_settings" do
    before do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    end

    describe "#effective_review_settings" do
      it "returns defaults when review_settings is empty" do
        project = build(:project, review_settings: {})
        settings = project.effective_review_settings

        expect(settings["enabled"]).to be false
        expect(settings["wait_for_reviews"]).to be true
        expect(settings.dig("methods", "copilot", "enabled")).to be false
        expect(settings.dig("methods", "paid_agent", "termination", "max_review_rounds")).to eq(15)
      end

      it "merges custom settings over defaults" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
        settings = project.effective_review_settings

        expect(settings["enabled"]).to be true
        expect(settings.dig("methods", "copilot", "enabled")).to be true
        expect(settings.dig("methods", "copilot", "termination", "max_review_rounds")).to eq(15)
      end

      it "handles non-Hash review_settings gracefully" do
        project = build(:project)
        project.review_settings = "invalid"
        settings = project.effective_review_settings

        expect(settings["enabled"]).to be false
        expect(settings.dig("methods", "copilot", "enabled")).to be false
      end
    end

    describe "#review_enabled?" do
      it "returns false by default" do
        project = build(:project)
        expect(project.review_enabled?).to be false
      end

      it "returns true when enabled" do
        project = build(:project, review_settings: { "enabled" => true })
        expect(project.review_enabled?).to be true
      end
    end

    describe "#wait_for_reviews?" do
      it "returns true by default" do
        project = build(:project)
        expect(project.wait_for_reviews?).to be true
      end

      it "returns false when explicitly disabled" do
        project = build(:project, review_settings: { "wait_for_reviews" => false })
        expect(project.wait_for_reviews?).to be false
      end
    end

    describe "#address_all_bot_reviews?" do
      it "returns false by default" do
        project = build(:project)
        expect(project.address_all_bot_reviews?).to be false
      end

      it "returns true when enabled" do
        project = build(:project, review_settings: { "address_all_bot_reviews" => true })
        expect(project.address_all_bot_reviews?).to be true
      end

      it "returns false when explicitly disabled" do
        project = build(:project, review_settings: { "address_all_bot_reviews" => false })
        expect(project.address_all_bot_reviews?).to be false
      end
    end

    describe "#review_method_enabled?" do
      it "returns false by default" do
        project = build(:project)
        expect(project.review_method_enabled?(:copilot)).to be false
      end

      it "returns true when method is enabled" do
        project = build(:project, review_settings: {
          "methods" => { "copilot" => { "enabled" => true } }
        })
        expect(project.review_method_enabled?(:copilot)).to be true
      end
    end

    describe "#ensure_paid_reviewer_bot_allowlisted" do
      it "adds the paid reviewer bot login when paid agent reviews are enabled" do
        project = build(:project,
          allowed_github_usernames: [ "viamin" ],
          review_settings: {
            "enabled" => true,
            "methods" => { "paid_agent" => { "enabled" => true } }
          })

        project.valid?

        expect(project.allowed_github_usernames).to include(
          "viamin",
          "paid-code-reviewer[bot]"
        )
        expect(project.allowed_github_usernames).not_to include("paid-code-reviewer")
      end

      it "does not add paid reviewer logins when paid agent reviews are disabled" do
        project = build(:project,
          allowed_github_usernames: [ "viamin" ],
          review_settings: {
            "enabled" => true,
            "methods" => { "paid_agent" => { "enabled" => false } }
          })

        project.valid?

        expect(project.allowed_github_usernames).to eq([ "viamin" ])
      end

      it "removes the managed bot login when paid agent reviews are disabled" do
        project = build(:project,
          allowed_github_usernames: [ "viamin", "paid-code-reviewer[bot]" ],
          review_settings: {
            "enabled" => true,
            "methods" => { "paid_agent" => { "enabled" => false } }
          })

        project.valid?

        expect(project.allowed_github_usernames).to eq([ "viamin" ])
      end
    end

    describe "#enabled_review_methods" do
      it "returns empty array by default" do
        project = build(:project)
        expect(project.enabled_review_methods).to be_empty
      end

      it "returns only enabled methods" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => { "enabled" => true },
            "paid_agent" => { "enabled" => true },
            "ci_action" => { "enabled" => false }
          }
        })
        expect(project.enabled_review_methods).to contain_exactly("copilot", "paid_agent")
      end
    end

    describe "#enabled_review_bot_logins" do
      it "returns empty set when no review methods have bot accounts" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "manual" => { "enabled" => true } }
        })
        expect(project.enabled_review_bot_logins).to be_empty
      end

      it "returns copilot logins when copilot method is enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
        expect(project.enabled_review_bot_logins).to include("copilot", "copilot[bot]")
      end

      it "returns codex logins when codex method is enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "codex" => { "enabled" => true } }
        })
        expect(project.enabled_review_bot_logins).to include("chatgpt-codex-connector", "chatgpt-codex-connector[bot]")
      end

      it "returns paid_agent logins when paid_agent is enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "paid_agent" => { "enabled" => true } }
        })
        expect(project.enabled_review_bot_logins).to include("paid-code-reviewer", "paid-code-reviewer[bot]")
      end

      it "does not include logins for disabled methods" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "copilot" => { "enabled" => false },
            "codex" => { "enabled" => true }
          }
        })
        expect(project.enabled_review_bot_logins).not_to include("copilot")
        expect(project.enabled_review_bot_logins).to include("chatgpt-codex-connector")
      end

      it "includes author-bot logins when project uses GitHub App installation" do
        project = build(:project, :with_github_installation, review_settings: { "enabled" => false })
        expect(project.enabled_review_bot_logins).to include("paid-agents", "paid-agents[bot]")
      end
    end

    # @spec GITHUB-SYNC-003
    describe "#github_credential" do
      it "returns PAT token for PAT-backed project" do
        github_token = build(:github_token, token: "ghp_test123")
        project = build(:project, github_token: github_token)
        expect(project.github_credential).to eq("ghp_test123")
      end

      it "returns nil for PAT-backed project with revoked token" do
        github_token = build(:github_token, token: "ghp_test123", revoked_at: Time.current)
        project = build(:project, github_token: github_token)
        expect(project.github_credential).to be_nil
      end

      it "returns nil for PAT-backed project with nil token" do
        project = build(:project, github_token: nil, github_installation: nil)
        expect(project.github_credential).to be_nil
      end

      it "returns installation token for app-backed project when App is configured" do
        key = OpenSSL::PKey::RSA.new(2048).to_pem
        ENV["PAID_AGENT_APP_ID"] = "123"
        ENV["PAID_AGENT_APP_PRIVATE_KEY"] = key

        stub_request(:post, %r{/app/installations/\d+/access_tokens})
          .to_return(status: 201, body: { token: "ghs_app_token" }.to_json)

        install = build(:github_installation, github_installation_id: 42)
        project = build(:project, :with_github_installation, github_installation: install)
        expect(project.github_credential).to eq("ghs_app_token")
      end

      it "returns nil for app-backed project with inactive installation" do
        install = build(:github_installation, github_installation_id: 42, revoked_at: Time.current)
        project = build(:project, :with_github_installation, github_installation: install)
        expect(project.github_credential).to be_nil
      end
    end

    describe "#git_push_pat_fallback_configured? and #git_push_fallback_credential" do
      def app_backed_project(account, **attrs)
        build(:project, :with_github_installation, account: account, **attrs)
      end

      it "is configured when enabled with an active fallback token on an app-backed project" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project.git_push_pat_fallback_configured?).to be(true)
        expect(project.git_push_fallback_credential).to eq(fallback.token)
      end

      it "is not configured when the setting is disabled, even with a token attached" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: false, git_push_fallback_token: fallback)

        expect(project.git_push_pat_fallback_configured?).to be(false)
        expect(project.git_push_fallback_credential).to be_nil
      end

      it "is not configured when the fallback token is revoked" do
        account = create(:account)
        fallback = create(:github_token, :revoked, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project.git_push_pat_fallback_configured?).to be(false)
        expect(project.git_push_fallback_credential).to be_nil
      end

      it "does not depend on the token's reported scopes (fine-grained tokens report none)" do
        account = create(:account)
        fallback = create(:github_token, account: account, scopes: [])
        project = app_backed_project(account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project.git_push_pat_fallback_configured?).to be(true)
      end

      it "is not configured for token-backed projects (no App installation)" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = build(:project, account: account, github_token: create(:github_token, account: account),
          git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project.git_push_pat_fallback_configured?).to be(false)
      end

      it "never mints an App installation token (the App remains the default credential)" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)
        allow(Github::AppInstallation).to receive(:token_for)

        project.git_push_fallback_credential

        expect(Github::AppInstallation).not_to have_received(:token_for)
      end
    end

    describe "#git_push_fallback_client" do
      def app_backed_project(account, **attrs)
        build(:project, :with_github_installation, account: account, **attrs)
      end

      it "returns the fallback token's client when fallback is configured" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback)

        expect(project.git_push_fallback_client).to eq(fallback.client)
      end

      it "returns nil when fallback is not configured" do
        account = create(:account)
        fallback = create(:github_token, account: account)
        project = app_backed_project(account, git_push_pat_fallback_enabled: false, git_push_fallback_token: fallback)

        expect(project.git_push_fallback_client).to be_nil
      end
    end

    describe "#github_auth_source" do
      it "returns pat for token-backed projects" do
        project = build(:project)

        expect(project.github_auth_source).to eq("pat")
      end

      it "returns app for app-backed projects" do
        project = build(:project, :with_github_installation)

        expect(project.github_auth_source).to eq("app")
      end
    end

    describe "#paid_agents_installation" do
      it "returns the installation that covers the repository" do
        account = create(:account)
        installation = create(:github_installation, account: account, accessible_repositories: [ { "full_name" => "acme/widgets" } ])
        project = build(:project, account: account, github_token: create(:github_token, account: account), owner: "acme", repo: "widgets")

        expect(project.paid_agents_installation(installations: [ installation ])).to eq(installation)
      end

      it "returns nil when no installation covers the repository" do
        account = create(:account)
        installation = create(:github_installation, account: account, accessible_repositories: [ { "full_name" => "acme/other" } ])
        project = build(:project, account: account, github_token: create(:github_token, account: account), owner: "acme", repo: "widgets")

        expect(project.paid_agents_installation(installations: [ installation ])).to be_nil
      end
    end

    describe "#github_author_login" do
      it "returns the bot login for app-backed projects" do
        project = build(:project, :with_github_installation)
        expect(project.github_author_login).to eq("paid-agents[bot]")
      end

      it "returns nil for PAT-backed project" do
        github_token = build(:github_token)
        project = build(:project, github_token: github_token)
        expect(project.github_author_login).to be_nil
      end
    end

    describe "#author_bot_logins" do
      it "returns empty set for PAT-backed projects" do
        project = build(:project)
        expect(project.author_bot_logins).to eq(Set.new)
      end

      it "returns app bot logins for app-backed projects" do
        project = build(:project, :with_github_installation)
        expect(project.author_bot_logins).to include("paid-agents", "paid-agents[bot]")
      end
    end

    describe "#client" do
      it "reuses the PAT-backed token client" do
        github_client = instance_double(GithubClient)
        github_token = instance_double(GithubToken, client: github_client)
        project = build(:project, github_installation: nil)

        allow(project).to receive(:github_token).and_return(github_token)

        expect(project.client).to be(github_client)
      end

      it "builds a GithubClient from the app-backed installation credential" do
        project = build(:project, :with_github_installation)
        github_client = instance_double(GithubClient)

        allow(project).to receive(:github_credential).and_return("ghs_app_token")
        allow(GithubClient).to receive(:new).with(
          token: "ghs_app_token",
          health_endpoint: project.github_health_endpoint,
          token_refresher: instance_of(Proc)
        ).and_return(github_client)

        expect(project.client).to be(github_client)
      end
    end

    describe "#installation_token_refresher" do
      it "returns a proc that clears cache and re-mints the token" do
        project = build(:project, :with_github_installation)
        fresh_token = "ghs_refreshed_token_abc"

        expect(Github::AppInstallation).to receive(:clear_cached_token).with(
          installation_id: project.github_installation.github_installation_id,
          repo_full_name: project.full_name
        )
        allow(project).to receive(:github_credential).and_return(fresh_token)

        result = project.installation_token_refresher.call
        expect(result).to eq(fresh_token)
      end

      it "returns nil for PAT-backed projects" do
        project = build(:project, github_installation: nil)

        expect(project.installation_token_refresher).to be_nil
      end
    end

    describe "exactly_one_github_credential validation" do
      it "allows unsaved projects without a credential" do
        project = build(:project, github_token: nil, github_installation: nil)

        expect(project).to be_valid
      end

      it "rejects project with both github_token and github_installation" do
        token = create(:github_token)
        install = create(:github_installation, account: token.account)
        project = build(:project, github_token: token, github_installation: install,
                       account: token.account)
        expect(project).not_to be_valid
        expect(project.errors[:base]).to include(/must have either a GitHub App installation or a PAT/)
      end

      it "accepts project with only github_token" do
        token = create(:github_token)
        project = build(:project, github_token: token, github_installation: nil, account: token.account)
        expect(project).to be_valid
      end

      it "accepts project with only github_installation" do
        install = create(:github_installation)
        project = build(:project, github_token: nil, github_installation: install, account: install.account)
        expect(project).to be_valid
      end

      it "rejects persisted projects without a credential" do
        project = create(:project)
        project.github_token = nil

        expect(project).not_to be_valid
        expect(project.errors[:base]).to include("must have a GitHub App installation or a PAT")
      end
    end

    describe "#review_bot_request_login" do
      it "returns nil when no review method is enabled" do
        project = build(:project, review_settings: { "enabled" => false })
        expect(project.review_bot_request_login).to be_nil
      end

      it "returns nil when reviews are globally disabled even if a method sub-flag is enabled" do
        project = build(:project, review_settings: {
          "enabled" => false,
          "methods" => { "codex" => { "enabled" => true } }
        })
        expect(project.review_bot_request_login).to be_nil
      end

      it "returns copilot login when copilot is enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
        expect(project.review_bot_request_login).to eq(Activities::RequestReviewActivity::COPILOT_LOGIN)
      end

      it "returns codex login when only codex is enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "codex" => { "enabled" => true } }
        })
        expect(project.review_bot_request_login).to eq(Activities::RequestReviewActivity::CODEX_LOGIN)
      end

      it "prefers copilot over codex when both are enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "copilot" => { "enabled" => true },
            "codex" => { "enabled" => true }
          }
        })
        expect(project.review_bot_request_login).to eq(Activities::RequestReviewActivity::COPILOT_LOGIN)
      end

      it "returns nil for enabled methods with no bot account" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "manual" => { "enabled" => true } }
        })
        expect(project.review_bot_request_login).to be_nil
      end
    end

    describe "#review_bot_request_chain" do
      it "returns an empty array when reviews are globally disabled" do
        project = build(:project, review_settings: {
          "enabled" => false,
          "methods" => { "copilot" => { "enabled" => true }, "codex" => { "enabled" => true } }
        })
        expect(project.review_bot_request_chain).to eq([])
      end

      it "returns the ordered fallback chain when both bots are enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true }, "codex" => { "enabled" => true } }
        })
        expect(project.review_bot_request_chain).to eq(
          [ Activities::RequestReviewActivity::COPILOT_LOGIN, Activities::RequestReviewActivity::CODEX_LOGIN ]
        )
      end

      it "returns only the enabled bot when one of the two is disabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "codex" => { "enabled" => true } }
        })
        expect(project.review_bot_request_chain).to eq([ Activities::RequestReviewActivity::CODEX_LOGIN ])
      end
    end

    describe "#review_method_config" do
      it "returns merged config for a method" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => { "timeout_minutes" => 60 }
            }
          }
        })
        config = project.review_method_config(:paid_agent)

        expect(config["enabled"]).to be true
        expect(config.dig("termination", "timeout_minutes")).to eq(60)
        expect(config.dig("termination", "max_review_rounds")).to eq(15)
      end
    end

    describe "#review_method" do
      it "returns the ReviewMethod value object with merged termination defaults" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => { "timeout_minutes" => 60 }
            }
          }
        })
        method = project.review_method(:paid_agent)

        expect(method).to be_a(Automation::Configuration::ReviewMethod)
        expect(method.enabled?).to be true
        expect(method.timeout_minutes).to eq(60)
        expect(method.max_review_rounds).to eq(15)
      end

      it "returns a disabled method when the review settings are empty" do
        project = build(:project, review_settings: {})
        expect(project.review_method(:paid_agent).enabled?).to be false
      end
    end

    describe "#automation_configuration" do
      it "exposes the aggregate Automation::Configuration::Project value object" do
        project = build(:project, auto_pick_enabled: true, auto_merge_mode: "all")

        config = project.automation_configuration

        expect(config).to be_a(Automation::Configuration::Project)
        expect(config.auto_pick.enabled?).to be true
        expect(config.auto_merge.enabled?).to be true
      end

      it "memoizes the configuration across calls" do
        project = build(:project)
        expect(project.automation_configuration).to equal(project.automation_configuration)
      end

      it "invalidates the memoized configuration when review_settings= is assigned" do
        project = build(:project, review_settings: { "enabled" => false })
        original = project.automation_configuration

        project.review_settings = { "enabled" => true,
                                    "methods" => { "paid_agent" => { "enabled" => true } } }

        expect(project.automation_configuration).not_to equal(original)
        expect(project.automation_configuration.auto_review.enabled?).to be true
      end
    end

    describe "#effective_auto_pick_skip_labels" do
      it "uses project labels before user, tenant, and defaults" do
        project = create(:project, auto_pick_skip_labels: %w[blocked])
        project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
        project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])

        expect(project.effective_auto_pick_skip_labels).to eq(%w[blocked])
      end

      it "falls back to user labels when the project does not override them" do
        project = create(:project, auto_pick_skip_labels: nil)
        project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
        project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])

        expect(project.effective_auto_pick_skip_labels).to eq(%w[user-skip])
      end

      it "falls back to tenant labels when the project and user do not override them" do
        project = create(:project, auto_pick_skip_labels: nil)
        project.created_by.settings.update!(auto_pick_skip_labels: nil)
        project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])

        expect(project.effective_auto_pick_skip_labels).to eq(%w[tenant-skip])
      end

      it "falls back to built-in defaults when no override exists" do
        project = create(:project, auto_pick_skip_labels: nil)
        project.created_by.settings.update!(auto_pick_skip_labels: nil)
        project.account.tenant_setting!.update!(auto_pick_skip_labels: nil)

        expect(project.effective_auto_pick_skip_labels).to eq(AutoPickSkipLabels::DEFAULTS)
      end

      it "allows a project override to disable skip labels entirely" do
        project = create(:project, auto_pick_skip_labels: [])
        project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])

        expect(project.effective_auto_pick_skip_labels).to eq([])
      end

      it "does not create a user setting record while resolving fallback labels" do
        project = create(:project)

        expect(project.created_by.user_setting).to be_nil
        expect { project.effective_auto_pick_skip_labels }.not_to change(UserSetting, :count)
        expect(project.effective_auto_pick_skip_labels).to eq(AutoPickSkipLabels::DEFAULTS)
      end
    end

    describe "#effective_screenshot_settings" do
      it "returns defaults when screenshot_settings is empty" do
        project = build(:project, screenshot_settings: {})

        expect(project.effective_screenshot_settings).to eq(
          "enabled" => false,
          "driver" => "playwright",
          "config_path" => ".paid/screenshots.yml",
          "auto_capture" => true,
          "record_video" => false,
          "service_dependencies" => [],
          "setup_commands" => [],
          "detection" => {},
          "verification_enabled" => false,
          "performance" => PageLoadPerformance::Settings::DEFAULTS
        )
      end

      it "merges screenshot defaults with stored settings" do
        project = build(:project, screenshot_settings: { "enabled" => true })

        expect(project.effective_screenshot_settings).to eq(
          "enabled" => true,
          "driver" => "playwright",
          "config_path" => ".paid/screenshots.yml",
          "auto_capture" => true,
          "record_video" => false,
          "service_dependencies" => [],
          "setup_commands" => [],
          "detection" => {},
          "verification_enabled" => false,
          "performance" => PageLoadPerformance::Settings::DEFAULTS
        )
      end
    end

    describe "screenshot accessors" do
      it "reads and writes individual settings" do
        project = build(:project, screenshot_settings: {})

        project.screenshot_enabled = true
        project.screenshot_driver = "cuprite"

        expect(project.screenshot_settings).to eq(
          "enabled" => true,
          "driver" => "cuprite"
        )
        expect(project.screenshot_enabled?).to be true
        expect(project.screenshot_driver).to eq("cuprite")
      end

      it "supports incremental updates without pre-populated defaults" do
        project = build(:project, screenshot_settings: {})

        project.screenshot_enabled = true

        expect(project).to be_valid
        expect(project.screenshot_settings).to eq("enabled" => true)
        expect(project.effective_screenshot_settings).to eq(
          "enabled" => true,
          "driver" => "playwright",
          "config_path" => ".paid/screenshots.yml",
          "auto_capture" => true,
          "record_video" => false,
          "service_dependencies" => [],
          "setup_commands" => [],
          "detection" => {},
          "verification_enabled" => false,
          "performance" => PageLoadPerformance::Settings::DEFAULTS
        )
      end
    end

    describe "#screenshots_enabled?" do
      it "returns false by default" do
        expect(build(:project).screenshots_enabled?).to be false
      end

      it "reflects the enabled flag" do
        expect(build(:project, screenshot_settings: { "enabled" => true }).screenshots_enabled?).to be true
      end
    end

    describe "#verification_enabled?" do
      it "returns false by default" do
        expect(build(:project).verification_enabled?).to be false
      end

      it "reflects the verification_enabled flag" do
        project = build(:project, screenshot_settings: { "verification_enabled" => true })
        expect(project.verification_enabled?).to be true
      end

      it "does not attach MCP definitions during attribute assignment" do
        project = described_class.new

        expect { project.verification_enabled = true }.not_to raise_error
      end

      it "casts string values to booleans" do
        project = build(:project, screenshot_settings: { "verification_enabled" => "true" })
        expect(project.verification_enabled?).to be true
      end

      it "attaches the playwright-mcp MCP server definition when enabled" do
        account = create(:account)
        project = create(:project, account: account, screenshot_settings: {})

        expect {
          project.verification_enabled = true
          project.save!
        }.to change { project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count }.by(1)

        definition = project.account.mcp_server_definitions.find_by(name: Project::PLAYWRIGHT_MCP_NAME)
        expect(definition).to have_attributes(
          transport: "stdio",
          install_type: "npx",
          command: Project::PLAYWRIGHT_MCP_COMMAND,
          metadata: Project::PLAYWRIGHT_MCP_METADATA
        )
        expect(definition.env).to eq("CDP_URL" => Project::PLAYWRIGHT_MCP_CDP_URL)
        expect(project.project_mcp_servers.reload.exists?(mcp_server_definition: definition)).to be true
      end

      it "attaches the MCP definition when toggled on via the screenshot_settings hash" do
        account = create(:account)
        project = create(:project, account: account, screenshot_settings: { "verification_enabled" => false })

        expect {
          project.update!(screenshot_settings: { "verification_enabled" => true })
        }.to change { project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count }.by(1)

        definition = project.account.mcp_server_definitions.find_by(name: Project::PLAYWRIGHT_MCP_NAME)
        expect(project.project_mcp_servers.exists?(mcp_server_definition: definition)).to be true
      end

      it "repairs an existing system-owned playwright-mcp definition before attaching it" do
        account = create(:account)
        stale_definition = create_stale_playwright_definition(account)
        project = create(:project, account: account, screenshot_settings: { "verification_enabled" => false })

        expect {
          project.update!(screenshot_settings: { "verification_enabled" => true })
        }.not_to change { project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count }

        expect(stale_definition.reload).to have_attributes(playwright_mcp_expected_attributes)
        expect(project.project_mcp_servers.exists?(mcp_server_definition: stale_definition)).to be true
      end

      it "does not rewrite a user-managed definition that happens to use the reserved name" do
        account = create(:account)
        create(:mcp_server_definition,
          account: account,
          name: Project::PLAYWRIGHT_MCP_NAME,
          transport: "stdio",
          install_type: "npx",
          command: "custom-playwright-wrapper",
          args: [ "--custom" ],
          env: { "TOKEN" => "secret" },
          metadata: { "owner" => "user" })

        project = build(:project, account: account, screenshot_settings: { "verification_enabled" => true })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings]).to include(/reserved MCP definition/)
      end

      it "does not re-attach when verification_enabled stays true" do
        account = create(:account)
        project = create(:project, account: account, screenshot_settings: { "verification_enabled" => true })
        project.account.mcp_server_definitions.find_or_create_by!(name: Project::PLAYWRIGHT_MCP_NAME) do |record|
          record.transport = "stdio"
          record.install_type = "npx"
          record.command = Project::PLAYWRIGHT_MCP_COMMAND
          record.metadata = Project::PLAYWRIGHT_MCP_METADATA
        end

        expect {
          project.update!(name: project.name + " updated")
        }.not_to change {
          project.account.mcp_server_definitions.where(name: Project::PLAYWRIGHT_MCP_NAME).count
        }
      end

      def create_stale_playwright_definition(account)
        create(:mcp_server_definition,
          account: account,
          name: Project::PLAYWRIGHT_MCP_NAME,
          transport: "stdio",
          install_type: "npx",
          command: "stale-command",
          args: [ "--stale" ],
          env: {},
          enabled: false,
          metadata: Project::PLAYWRIGHT_MCP_METADATA)
      end

      def playwright_mcp_expected_attributes
        {
          transport: "stdio",
          install_type: "npx",
          command: Project::PLAYWRIGHT_MCP_COMMAND,
          args: [],
          env: { "CDP_URL" => Project::PLAYWRIGHT_MCP_CDP_URL },
          metadata: Project::PLAYWRIGHT_MCP_METADATA,
          enabled: true
        }
      end
    end

    describe "validation" do
      it "accepts empty review_settings" do
        project = build(:project, review_settings: {})
        expect(project).to be_valid
      end

      it "accepts valid review_settings" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "wait_for_reviews" => true,
          "methods" => {
            "copilot" => {
              "enabled" => true,
              "termination" => { "max_review_rounds" => 2, "stop_when_no_comments" => true }
            }
          }
        })
        expect(project).to be_valid
      end

      it "accepts valid screenshot_settings" do
        project = build(:project, screenshot_settings: {
          "enabled" => true,
          "driver" => "cuprite",
          "record_video" => true,
          "framework" => "nextjs",
          "viewport" => { "width" => 1440 }
        })

        expect(project).to be_valid
      end

      it "rejects non-hash screenshot_settings" do
        project = build(:project, screenshot_settings: "bad")

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("must be a JSON object")
      end

      it "rejects unknown screenshot drivers" do
        project = build(:project, screenshot_settings: { "driver" => "selenium" })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("driver must be one of: playwright, cuprite")
      end

      it "rejects unknown screenshot frameworks" do
        project = build(:project, screenshot_settings: { "framework" => "laravel" })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("framework must be one of: rails, nextjs, django, phoenix, generic")
      end

      it "accepts Phoenix screenshot frameworks" do
        project = build(:project, screenshot_settings: { "framework" => "phoenix" })

        expect(project).to be_valid
      end

      it "rejects unknown screenshot_settings keys" do
        project = build(:project, screenshot_settings: { "enabled" => true, "bogus" => 1 })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("unknown keys: bogus")
      end

      it "accepts the record_video screenshot setting" do
        project = build(:project, screenshot_settings: { "enabled" => true, "record_video" => true })

        expect(project).to be_valid
      end

      it "rejects a non-boolean record_video screenshot setting" do
        project = build(:project, screenshot_settings: { "record_video" => "yes" })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("record_video must be true or false")
      end

      it "rejects invalid viewport in screenshot_settings" do
        project = build(:project, screenshot_settings: { "viewport" => "bad" })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("viewport must be a mapping")
      end

      it "rejects invalid base_url in screenshot_settings" do
        project = build(:project, screenshot_settings: { "base_url" => 123 })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("base_url must be a non-blank string")
      end

      it "rejects non-positive viewport dimensions" do
        project = build(:project, screenshot_settings: { "viewport" => { "width" => -1, "height" => 900 } })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("viewport.width must be a positive integer")
      end

      it "rejects non-string items in ui_patterns" do
        project = build(:project, screenshot_settings: { "ui_patterns" => [ 123 ] })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("ui_patterns[0] must be a non-blank string")
      end

      it "rejects invalid auth strategy" do
        project = build(:project, screenshot_settings: { "auth" => { "strategy" => "bogus" } })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("auth.strategy must be one of")
      end

      it "rejects non-hash seed items" do
        project = build(:project, screenshot_settings: { "seed" => [ 123 ] })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("seed[0] must be a mapping")
      end

      it "rejects non-string setup items" do
        project = build(:project, screenshot_settings: { "setup" => [ 456 ] })

        expect(project).not_to be_valid
        expect(project.errors[:screenshot_settings].join).to include("setup[0] must be a non-blank string")
      end

      it "stores and retrieves screenshot_settings via JSONB" do
        settings = {
          "enabled" => true,
          "driver" => "cuprite",
          "viewport" => { "width" => 1440, "height" => 900 }
        }
        project = create(:project, screenshot_settings: settings)

        reloaded = described_class.find(project.id)

        expect(reloaded.screenshot_settings).to eq(settings)
        expect(reloaded.effective_screenshot_settings)
          .to eq(described_class::DEFAULT_SCREENSHOT_SETTINGS.merge(settings))
      end

      it "rejects unknown review methods" do
        project = build(:project, review_settings: {
          "methods" => { "unknown_method" => { "enabled" => true } }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("unknown review method")
      end

      it "rejects non-positive max_review_rounds" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => {
              "enabled" => true,
              "termination" => { "max_review_rounds" => 0 }
            }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("max_review_rounds must be a positive integer")
      end

      it "rejects non-positive timeout_minutes" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => { "timeout_minutes" => -5 }
            }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("timeout_minutes must be a positive integer")
      end

      it "rejects paid_agent when the review bot credentials are not configured" do
        allow(Github::ReviewBotInstallationToken).to receive_messages(configured?: false, private_key: nil)

        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => {
              "enabled" => true
            }
          }
        })

        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("paid-code-reviewer GitHub App credentials are not configured")
      end

      it "rejects paid_agent with a distinct message when the private key is set but malformed" do
        # Surfaces the actual root cause (e.g. wrong key format) so a user
        # who just configured the credential isn't sent in circles trying
        # to re-add a key that's already there.
        allow(Github::ReviewBotInstallationToken).to receive_messages(
          configured?: false,
          private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nfoo\n-----END OPENSSH PRIVATE KEY-----\n"
        )

        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true }
          }
        })

        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join)
          .to include("private key is present but cannot be parsed as RSA")
      end

      it "rejects enabled reviews with no methods enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "copilot" => { "enabled" => false }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("at least one review method enabled")
      end

      it "rejects enabled reviews with no methods key" do
        project = build(:project, review_settings: { "enabled" => true })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("at least one review method enabled")
      end

      it "rejects enabled method with no termination conditions" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => nil,
                "stop_when_no_comments" => false,
                "quality_threshold" => nil,
                "timeout_minutes" => nil
              }
            }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("at least one termination condition")
      end

      it "accepts max_review_goal_retries as sole termination condition for paid_agent" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => nil,
                "max_review_goal_retries" => 3,
                "stop_when_no_comments" => false,
                "quality_threshold" => nil,
                "timeout_minutes" => nil
              }
            }
          }
        })
        expect(project).to be_valid
      end

      it "rejects max_review_goal_retries as sole termination condition for non-paid_agent methods" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => nil,
                "max_review_goal_retries" => 3,
                "stop_when_no_comments" => false,
                "quality_threshold" => nil,
                "timeout_minutes" => nil
              }
            }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("at least one termination condition")
      end

      it "rejects paid_agent max_review_goal_retries exceeding max_review_rounds" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => 3,
                "max_review_goal_retries" => 5,
                "stop_when_no_comments" => false,
                "quality_threshold" => nil,
                "timeout_minutes" => nil
              }
            }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("max_review_goal_retries (5) must not exceed max_review_rounds (3)")
      end

      it "accepts paid_agent max_review_goal_retries equal to max_review_rounds" do
        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => 3,
                "max_review_goal_retries" => 3,
                "stop_when_no_comments" => false,
                "quality_threshold" => nil,
                "timeout_minutes" => nil
              }
            }
          }
        })
        expect(project).to be_valid
      end

      it "falls back to default termination when termination key is missing" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => { "enabled" => true }
          }
        })
        # copilot defaults include stop_when_no_comments: true, so this is valid
        expect(project).to be_valid
      end

      it "falls back to default termination values when termination has partial overrides" do
        project = build(:project, review_settings: {
          "methods" => {
            "manual" => {
              "enabled" => true,
              "reviewer_login" => "alice",
              "termination" => {}
            }
          }
        })
        expect(project).to be_valid
      end

      it "accepts paid_agent max_review_rounds below the default retry limit" do
        allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)

        project = build(:project, review_settings: {
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => {
                "max_review_rounds" => 1
              }
            }
          }
        })
        expect(project).to be_valid
      end

      it "skips termination validation for disabled methods" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => {
              "enabled" => false,
              "termination" => { "max_review_rounds" => -1 }
            }
          }
        })
        expect(project).to be_valid
      end

      it "rejects review_settings set to an array" do
        project = build(:project, review_settings: [])
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("must be a JSON object")
      end

      it "rejects review_settings set to a string" do
        project = build(:project, review_settings: "invalid")
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("must be a JSON object")
      end

      it "rejects methods set to a non-Hash value" do
        project = build(:project, review_settings: { "methods" => "copilot" })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("methods must be a JSON object")
      end

      it "rejects methods set to an array" do
        project = build(:project, review_settings: { "methods" => [ "copilot" ] })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("methods must be a JSON object")
      end

      it "rejects a method config set to a non-Hash" do
        project = build(:project, review_settings: {
          "methods" => { "copilot" => "enabled" }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("copilot config must be a JSON object")
      end

      it "rejects termination set to a non-Hash for an enabled method" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => { "enabled" => true, "termination" => "invalid" }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("copilot termination must be a JSON object")
      end

      it "rejects ci_action with blank action_name when enabled" do
        project = build(:project, review_settings: {
          "methods" => {
            "ci_action" => { "enabled" => true, "action_name" => "", "termination" => { "max_review_rounds" => 1 } }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("ci_action requires a non-blank action_name")
      end

      it "rejects ci_action with nil action_name when enabled" do
        project = build(:project, review_settings: {
          "methods" => {
            "ci_action" => { "enabled" => true, "termination" => { "max_review_rounds" => 1 } }
          }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("ci_action requires a non-blank action_name")
      end

      it "accepts ci_action with action_name when enabled" do
        project = build(:project, review_settings: {
          "methods" => {
            "ci_action" => { "enabled" => true, "action_name" => "my-review-action", "termination" => { "max_review_rounds" => 1 } }
          }
        })
        expect(project).to be_valid
      end

      it "skips action_name validation when ci_action is disabled" do
        project = build(:project, review_settings: {
          "methods" => {
            "ci_action" => { "enabled" => false, "action_name" => "" }
          }
        })
        expect(project).to be_valid
      end

      it "validates correctly when review_settings has symbol keys" do
        project = build(:project, review_settings: {
          enabled: true,
          methods: {
            copilot: {
              enabled: true,
              termination: { max_review_rounds: 2, stop_when_no_comments: true }
            }
          }
        })
        expect(project).to be_valid
      end

      it "rejects unknown methods even with symbol keys" do
        project = build(:project, review_settings: {
          methods: { unknown_method: { enabled: true } }
        })
        expect(project).not_to be_valid
        expect(project.errors[:review_settings].join).to include("unknown review method")
      end

      it "stores and retrieves review_settings via JSONB" do
        settings = {
          "enabled" => true,
          "wait_for_reviews" => true,
          "methods" => {
            "copilot" => { "enabled" => true, "termination" => { "max_review_rounds" => 2 } }
          }
        }
        project = create(:project, review_settings: settings)
        reloaded = described_class.find(project.id)

        expect(reloaded.review_settings).to eq(settings)
      end
    end
  end

  describe "account association" do
    it "is destroyed when account is destroyed" do
      account = create(:account)
      create(:user, account: account)
      project = create(:project, account: account)

      expect { account.destroy }.to change(described_class, :count).by(-1)
      expect { project.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "github_token association" do
    it "prevents deletion of github_token with projects" do
      project = create(:project)
      github_token = project.github_token

      expect { github_token.destroy }.not_to change(GithubToken, :count)
      expect(github_token.errors[:base]).to include("Cannot delete record because dependent projects exist")
    end
  end

  describe "user association" do
    it "allows project to exist without creator" do
      project = create(:project, :without_creator)
      expect(project.created_by).to be_nil
      expect(project).to be_valid
    end

    it "sets created_by to nil when user is destroyed" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)

      user.destroy
      project.reload

      expect(project.created_by).to be_nil
    end
  end

  describe "broadcast methods" do
    let(:project) { create(:project) }

    before do
      allow(project).to receive(:broadcast_replace_to)
      allow(project).to receive(:broadcast_refresh_to)
    end

    describe "#broadcast_stats_update" do
      it "broadcasts replace to the project_updates stream with stats partial" do
        project.broadcast_stats_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "stats_project_#{project.id}",
          partial: "projects/stats",
          locals: hash_including(project: project)
        )
      end
    end

    describe "#broadcast_cost_snapshot_update" do
      it "broadcasts replace to the project_updates stream with cost snapshot partial" do
        project.broadcast_cost_snapshot_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "cost_snapshot_project_#{project.id}",
          partial: "projects/cost_snapshot",
          locals: hash_including(project: project, summary: hash_including(:today_cost_cents, :monthly_cost_cents))
        )
      end
    end

    describe "#broadcast_agent_runs_update" do
      it "broadcasts replace to the project_updates stream with agent_runs partial" do
        project.broadcast_agent_runs_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "agent_runs_project_#{project.id}",
          partial: "projects/agent_runs",
          locals: hash_including(project: project)
        )
      end
    end

    describe "#broadcast_issues_update" do
      it "broadcasts a refresh to the project_updates stream" do
        project.broadcast_issues_update

        expect(project).to have_received(:broadcast_refresh_to).with(project, :project_updates)
      end

      it "does not broadcast when broadcasts are suppressed" do
        described_class.suppress_broadcasts do
          project.broadcast_issues_update
        end

        expect(project).not_to have_received(:broadcast_refresh_to)
      end
    end

    describe "#broadcast_pull_requests_update" do
      it "broadcasts a refresh to the project_updates stream" do
        project.broadcast_pull_requests_update

        expect(project).to have_received(:broadcast_refresh_to).with(project, :project_updates)
      end

      it "does not broadcast when broadcasts are suppressed" do
        described_class.suppress_broadcasts do
          project.broadcast_pull_requests_update
        end

        expect(project).not_to have_received(:broadcast_refresh_to)
      end
    end

    describe "#broadcast_project_show_refresh" do
      it "broadcasts a refresh to the project_updates stream" do
        project.broadcast_project_show_refresh

        expect(project).to have_received(:broadcast_refresh_to).with(project, :project_updates)
      end
    end

    describe ".suppress_broadcasts" do
      it "restores the previous suppression state after the block" do
        expect(described_class).not_to be_broadcasts_suppressed

        described_class.suppress_broadcasts do
          expect(described_class).to be_broadcasts_suppressed
        end

        expect(described_class).not_to be_broadcasts_suppressed
      end

      it "restores state even when an error is raised" do
        expect {
          described_class.suppress_broadcasts do
            raise "test error"
          end
        }.to raise_error("test error")

        expect(described_class).not_to be_broadcasts_suppressed
      end

      it "supports nesting" do
        described_class.suppress_broadcasts do
          expect(described_class).to be_broadcasts_suppressed

          described_class.suppress_broadcasts do
            expect(described_class).to be_broadcasts_suppressed
          end

          expect(described_class).to be_broadcasts_suppressed
        end

        expect(described_class).not_to be_broadcasts_suppressed
      end
    end

    describe "#broadcast_workflow_status_update" do
      it "broadcasts replace with restart controls enabled" do
        health = {
          status: :unhealthy,
          label: "Not running",
          description: "The issue monitor is not running."
        }

        allow(WorkflowState).to receive(:compute_health_for).with(project).and_return(health)

        project.broadcast_workflow_status_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "workflow-status",
          partial: "workflow_statuses/status",
          locals: { project: project, health: health, show_restart: true }
        )
      end
    end

    describe "#broadcast_agent_runs_list_update" do
      it "broadcasts replace to the agent_runs_list stream with agent_runs/table partial" do
        project.broadcast_agent_runs_list_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :agent_runs_list,
          target: "agent_runs_list_project_#{project.id}",
          partial: "agent_runs/table",
          locals: hash_including(project: project)
        )
      end
    end

    describe "#broadcast_agent_run_detail_update" do
      it "broadcasts replace to the detail stream with agent_runs/detail partial" do
        agent_run = build_stubbed(:agent_run, project: project)

        project.broadcast_agent_run_detail_update(agent_run)

        expect(project).to have_received(:broadcast_replace_to).with(
          agent_run, :detail,
          target: "detail_agent_run_#{agent_run.id}",
          partial: "agent_runs/detail",
          locals: hash_including(agent_run: agent_run)
        ).once
      end

      it "swallows missing marketplace attachment table errors during the detail broadcast" do
        agent_run = build_stubbed(:agent_run, project: project)
        undefined_table = PG::UndefinedTable.new('ERROR: relation "agent_run_marketplace_entries" does not exist')
        error = ActiveRecord::StatementInvalid.new(
          'PG::UndefinedTable: ERROR: relation "agent_run_marketplace_entries" does not exist'
        )
        allow(error).to receive(:cause).and_return(undefined_table)
        allow(project).to receive(:broadcast_replace_to).and_raise(error)

        expect { project.broadcast_agent_run_detail_update(agent_run) }.not_to raise_error
      end

      it "re-raises unrelated statement errors from the detail broadcast" do
        agent_run = build_stubbed(:agent_run, project: project)
        error = ActiveRecord::StatementInvalid.new("boom")
        allow(project).to receive(:broadcast_replace_to).and_raise(error)

        expect { project.broadcast_agent_run_detail_update(agent_run) }.to raise_error(error)
      end
    end
  end

  describe "#semantic_search_available?" do
    it "returns true when an OpenAI key exists for the owner" do
      project = create(:project)
      owner = project.effective_owner
      create(:provider_api_key, user: owner, api_service_type: "openai")

      expect(project.semantic_search_available?).to be true
    end

    it "returns true when a platform OpenAI key is set" do
      project = create(:project)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-platform")

      expect(project.semantic_search_available?).to be true
    end

    it "returns true when a platform OpenAI key is available from Rails credentials" do
      project = create(:project)
      allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return("sk-platform")

      expect(project.semantic_search_available?).to be true
    end

    it "returns true when the configured knowledge embedding provider has a compatible key" do
      project = create(:project)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_runner: "openrouter", kb_embedding_fallback_runners: [])
      create(:provider_api_key, user: owner, api_service_type: "openrouter")

      expect(project.semantic_search_available?).to be true
    end

    it "returns false when no OpenAI key exists from any source" do
      project = create(:project)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)

      expect(project.semantic_search_available?).to be false
    end
  end

  describe "auto_release_granularity" do
    it "defaults to off" do
      project = build(:project)
      expect(project.auto_release_granularity).to eq("off")
    end

    it "validates inclusion in AUTO_RELEASE_GRANULARITIES" do
      project = build(:project, auto_release_granularity: "invalid")
      expect(project).not_to be_valid
      expect(project.errors[:auto_release_granularity]).to be_present
    end

    it "accepts all valid granularities" do
      Project::AUTO_RELEASE_GRANULARITIES.each do |granularity|
        project = build(:project, auto_release_granularity: granularity)
        expect(project).to be_valid
      end
    end
  end

  describe "#auto_release_enabled?" do
    it "returns false when granularity is off" do
      project = build(:project, auto_release_granularity: "off")
      expect(project.auto_release_enabled?).to be false
    end

    it "returns true when granularity is not off" do
      %w[patch_only minor_only major_only all].each do |granularity|
        project = build(:project, auto_release_granularity: granularity)
        expect(project.auto_release_enabled?).to be true
      end
    end
  end

  describe "#auto_release_allows_bump?" do
    it "returns false for all bumps when off" do
      project = build(:project, auto_release_granularity: "off")
      %w[major minor patch].each do |bump|
        expect(project.auto_release_allows_bump?(bump)).to be false
      end
    end

    it "allows only patch when patch_only" do
      project = build(:project, auto_release_granularity: "patch_only")
      expect(project.auto_release_allows_bump?("patch")).to be true
      expect(project.auto_release_allows_bump?("minor")).to be false
      expect(project.auto_release_allows_bump?("major")).to be false
    end

    it "allows minor and patch when minor_only" do
      project = build(:project, auto_release_granularity: "minor_only")
      expect(project.auto_release_allows_bump?("patch")).to be true
      expect(project.auto_release_allows_bump?("minor")).to be true
      expect(project.auto_release_allows_bump?("major")).to be false
    end

    it "allows all bumps when major_only" do
      project = build(:project, auto_release_granularity: "major_only")
      expect(project.auto_release_allows_bump?("patch")).to be true
      expect(project.auto_release_allows_bump?("minor")).to be true
      expect(project.auto_release_allows_bump?("major")).to be true
    end

    it "allows all bumps when all" do
      project = build(:project, auto_release_granularity: "all")
      %w[major minor patch].each do |bump|
        expect(project.auto_release_allows_bump?(bump)).to be true
      end
    end
  end

  describe "#auto_merge_enabled?" do
    it "returns false when mode is off" do
      project = build(:project, auto_merge_mode: "off")
      expect(project.auto_merge_enabled?).to be false
    end

    it "returns true when mode is dependabot_only" do
      project = build(:project, auto_merge_mode: "dependabot_only")
      expect(project.auto_merge_enabled?).to be true
    end

    it "returns true when mode is all" do
      project = build(:project, auto_merge_mode: "all")
      expect(project.auto_merge_enabled?).to be true
    end
  end

  describe "#auto_merge_dependabot?" do
    it "returns false when mode is off" do
      project = build(:project, auto_merge_mode: "off")
      expect(project.auto_merge_dependabot?).to be false
    end

    it "returns true when mode is dependabot_only" do
      project = build(:project, auto_merge_mode: "dependabot_only")
      expect(project.auto_merge_dependabot?).to be true
    end

    it "returns true when mode is all" do
      project = build(:project, auto_merge_mode: "all")
      expect(project.auto_merge_dependabot?).to be true
    end
  end

  describe "#scheduler_paused?" do
    it "returns false by default" do
      expect(build(:project).scheduler_paused?).to be false
    end

    it "returns true when scheduler_paused_at is set" do
      expect(build(:project, scheduler_paused_at: Time.current).scheduler_paused?).to be true
    end
  end

  describe "#scheduler_pause!" do
    let(:project) { create(:project) }

    it "sets scheduler_paused_at and reason" do
      project.scheduler_pause!(reason: "token expired")

      expect(project.scheduler_paused_at).to be_present
      expect(project.scheduler_pause_reason).to eq("token expired")
    end

    it "returns false if already paused" do
      project.update!(scheduler_paused_at: 1.hour.ago)

      expect(project.scheduler_pause!(reason: "token expired")).to be false
    end
  end

  describe "#scheduler_resume!" do
    let(:project) { create(:project, scheduler_paused_at: 1.hour.ago, scheduler_pause_reason: "token expired") }

    it "clears scheduler_paused_at and reason" do
      project.scheduler_resume!

      expect(project.scheduler_paused_at).to be_nil
      expect(project.scheduler_pause_reason).to be_nil
    end

    it "returns false if not paused" do
      project.update!(scheduler_paused_at: nil)

      expect(project.scheduler_resume!).to be false
    end
  end

  describe "#paused?" do
    it "returns false by default" do
      expect(build(:project).paused?).to be false
    end

    it "returns true when paused is set to true" do
      expect(build(:project, paused: true).paused?).to be true
    end
  end

  describe "#pause!" do
    let(:project) { create(:project) }

    it "sets paused to true" do
      project.pause!

      expect(project.reload.paused?).to be true
    end
  end

  describe "#unpause!" do
    let(:project) { create(:project, paused: true) }

    it "sets paused to false" do
      project.unpause!

      expect(project.reload.paused?).to be false
    end
  end

  describe "auto-resume on token change" do
    let(:account) { create(:account) }
    let(:old_token) { create(:github_token, account: account) }
    let(:new_token) { create(:github_token, account: account) }
    let(:project) do
      create(:project, account: account, github_token: old_token,
        scheduler_paused_at: 1.hour.ago, scheduler_pause_reason: "token expired")
    end

    it "clears the scheduler pause when github_token_id changes" do
      project.update!(github_token: new_token)

      expect(project.reload.scheduler_paused_at).to be_nil
      expect(project.reload.scheduler_pause_reason).to be_nil
    end

    it "does not clear pause when other attributes change" do
      project.update!(name: "New Name")

      expect(project.reload.scheduler_paused_at).to be_present
    end
  end
end
