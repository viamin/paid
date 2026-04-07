# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:github_token) }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
    it { is_expected.to have_many(:project_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:members).through(:project_memberships).source(:user) }
    it { is_expected.to have_many(:issues).dependent(:destroy) }
    it { is_expected.to have_many(:agent_runs).dependent(:destroy) }
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

    it "defaults max_execution_seconds to 1800" do
      project = build(:project)
      expect(project.max_execution_seconds).to eq(1800)
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

    describe "#github_url" do
      it "returns the GitHub URL" do
        project = build(:project, owner: "viamin", repo: "paid")
        expect(project.github_url).to eq("https://github.com/viamin/paid")
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
      allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
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
          task_queue: "paid-tasks"
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
          task_queue: "paid-tasks"
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

    before do
      allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
      allow(temporal_client).to receive(:start_workflow)
    end

    it "enqueues ProcessRunQueueJob when auto_pick is enabled" do
      project = create(:project, auto_pick_enabled: false)

      expect {
        project.update!(auto_pick_enabled: true)
      }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not enqueue ProcessRunQueueJob when auto_pick is disabled" do
      project = create(:project, auto_pick_enabled: true)

      expect {
        project.update!(auto_pick_enabled: false)
      }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not enqueue ProcessRunQueueJob when other attributes change" do
      project = create(:project, auto_pick_enabled: true)

      expect {
        project.update!(name: "new-name")
      }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "logs error when ProcessRunQueueJob fails to enqueue" do
      project = create(:project, auto_pick_enabled: false)
      allow(ProcessRunQueueJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
      allow(Rails.logger).to receive(:error)

      project.update!(auto_pick_enabled: true)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "auto_pick.trigger_failed", project_id: project.id)
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

  describe "agent_co_author_trailer validation" do
    it "allows a normal single-line trailer" do
      project = build(:project, agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")
      expect(project).to be_valid
    end

    it "allows blank trailer" do
      project = build(:project, agent_co_author_trailer: "")
      expect(project).to be_valid
    end

    it "allows nil trailer" do
      project = build(:project, agent_co_author_trailer: nil)
      expect(project).to be_valid
    end

    it "rejects trailer containing newline" do
      project = build(:project, agent_co_author_trailer: "Co-Authored-By: A\nCo-Authored-By: B")
      expect(project).not_to be_valid
      expect(project.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
    end

    it "rejects trailer containing carriage return" do
      project = build(:project, agent_co_author_trailer: "Co-Authored-By: A\rB")
      expect(project).not_to be_valid
      expect(project.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
    end

    it "strips leading and trailing whitespace before validation" do
      project = build(:project, agent_co_author_trailer: "  Co-Authored-By: Claude <noreply@anthropic.com>  ")
      project.valid?
      expect(project.agent_co_author_trailer).to eq("Co-Authored-By: Claude <noreply@anthropic.com>")
    end

    it "normalizes whitespace-only values to nil" do
      project = build(:project, agent_co_author_trailer: "   ")
      project.valid?
      expect(project.agent_co_author_trailer).to be_nil
    end
  end

  describe "review_settings" do
    describe "#effective_review_settings" do
      it "returns defaults when review_settings is empty" do
        project = build(:project, review_settings: {})
        settings = project.effective_review_settings

        expect(settings["enabled"]).to be false
        expect(settings["wait_for_reviews"]).to be true
        expect(settings.dig("methods", "copilot", "enabled")).to be false
        expect(settings.dig("methods", "paid_agent", "termination", "max_review_rounds")).to eq(3)
      end

      it "merges custom settings over defaults" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
        settings = project.effective_review_settings

        expect(settings["enabled"]).to be true
        expect(settings.dig("methods", "copilot", "enabled")).to be true
        expect(settings.dig("methods", "copilot", "termination", "max_review_rounds")).to eq(2)
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
        expect(config.dig("termination", "max_review_rounds")).to eq(3)
      end
    end

    describe "#blocking_review_methods" do
      it "defaults to copilot for legacy projects with reviews unset" do
        project = build(:project)

        expect(project.blocking_review_methods).to eq([ "copilot" ])
      end

      it "returns empty when reviews are explicitly disabled" do
        project = build(:project, review_settings: { "enabled" => false })

        expect(project.blocking_review_methods).to eq([])
      end

      it "returns enabled methods when reviews are enabled and blocking" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "wait_for_reviews" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "manual" => { "enabled" => true }
          }
        })

        expect(project.blocking_review_methods).to contain_exactly("paid_agent", "manual")
      end

      it "returns empty when wait_for_reviews is disabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "wait_for_reviews" => false,
          "methods" => {
            "paid_agent" => { "enabled" => true }
          }
        })

        expect(project.blocking_review_methods).to eq([])
      end
    end

    describe "#requested_review_methods" do
      it "defaults to copilot for legacy projects with reviews unset" do
        project = build(:project)

        expect(project.requested_review_methods).to eq([ "copilot" ])
      end

      it "returns empty when reviews are explicitly disabled" do
        project = build(:project, review_settings: { "enabled" => false })

        expect(project.requested_review_methods).to eq([])
      end

      it "returns only auto-requestable enabled methods" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "copilot" => { "enabled" => true },
            "paid_agent" => { "enabled" => true },
            "manual" => { "enabled" => true }
          }
        })

        expect(project.requested_review_methods).to contain_exactly("copilot", "paid_agent")
      end
    end

    describe "#ci_review_action_names" do
      it "returns configured ci action name when enabled" do
        project = build(:project, review_settings: {
          "enabled" => true,
          "methods" => {
            "ci_action" => { "enabled" => true, "action_name" => "codex-review" }
          }
        })

        expect(project.ci_review_action_names).to eq([ "codex-review" ])
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

      it "falls back to default termination when termination key is missing" do
        project = build(:project, review_settings: {
          "methods" => {
            "copilot" => { "enabled" => true }
          }
        })
        # copilot defaults include stop_when_no_comments: true, so this is valid
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
    end

    describe "#broadcast_stats_update" do
      it "broadcasts replace to the project_updates stream with stats partial" do
        project.broadcast_stats_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "stats_project_#{project.id}",
          partial: "projects/stats",
          locals: { project: project }
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
      it "broadcasts replace to the project_updates stream with issues partial" do
        project.broadcast_issues_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "issues_project_#{project.id}",
          partial: "projects/issues",
          locals: hash_including(project: project)
        )
      end
    end

    describe "#broadcast_pull_requests_update" do
      it "broadcasts replace to the project_updates stream with pull_requests partial" do
        project.broadcast_pull_requests_update

        expect(project).to have_received(:broadcast_replace_to).with(
          project, :project_updates,
          target: "pull_requests_project_#{project.id}",
          partial: "projects/pull_requests",
          locals: hash_including(project: project)
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
    end
  end

  describe "#openai_api_key" do
    it "returns the most recent OpenAI API key from the project owner" do
      project = create(:project)
      owner = project.effective_owner
      create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-old", created_at: 2.minutes.ago)
      create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-new", created_at: 1.minute.ago)

      expect(project.openai_api_key).to eq("sk-new")
    end

    it "returns nil when no OpenAI key exists" do
      project = create(:project)

      expect(project.openai_api_key).to be_nil
    end

    it "ignores non-OpenAI keys" do
      project = create(:project)
      owner = project.effective_owner
      create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-anthropic")

      expect(project.openai_api_key).to be_nil
    end
  end

  describe "#openai_api_key_configured?" do
    it "returns true when an OpenAI key exists" do
      project = create(:project)
      owner = project.effective_owner
      create(:provider_api_key, user: owner, api_service_type: "openai")

      expect(project.openai_api_key_configured?).to be true
    end

    it "returns false when no OpenAI key exists" do
      project = create(:project)

      expect(project.openai_api_key_configured?).to be false
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

    it "returns false when no OpenAI key exists from any source" do
      project = create(:project)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)

      expect(project.semantic_search_available?).to be false
    end
  end
end
