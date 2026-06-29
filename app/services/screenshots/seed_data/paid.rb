# frozen_string_literal: true

require "digest"

module Screenshots
  module SeedData
    class Paid
      class << self
        def call
          password = "screenshot-password-123"

          account = Account.find_or_create_by!(slug: "screenshot-account") do |record|
            record.name = "Screenshot Account"
          end

          user = User.find_or_initialize_by(email: "screenshot@example.com")
          user.account = account
          user.password = password
          user.password_confirmation = password
          user.save!

          unless user.account_memberships.exists?(account: account)
            user.account_memberships.create!(account: account, role: :owner)
          end

          user.settings.update!(
            allowed_service_images: [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ]
          )

          github_token = GithubToken.find_or_create_by!(account: account, name: "Screenshot Token") do |record|
            record.created_by = user
            record.token = "ghp_#{'a' * 36}"
            record.scopes = [ "repo" ]
            record.validation_status = "validated"
          end

          github_installation = GithubInstallation.find_or_create_by!(account: account, github_installation_id: 9_999_998) do |record|
            record.account_login = "paid"
            record.target_type = "Organization"
            record.repository_selection = "selected"
            record.accessible_repositories = [
              {
                "id" => 9_999_999,
                "full_name" => "paid/screenshots",
                "name" => "screenshots",
                "owner" => "paid",
                "default_branch" => "main",
                "private" => true
              }
            ]
          end

          project = Project.find_or_create_by!(account: account, github_id: 9_999_999) do |record|
            record.github_token = github_token
            record.created_by = user
            record.name = "Screenshot Project"
            record.owner = "paid"
            record.repo = "screenshots"
            record.default_branch = "main"
            record.poll_interval_seconds = 60
            record.label_mappings = {}
            record.allowed_github_usernames = [ user.email ]
          end

          installation_project = Project.find_or_create_by!(account: account, github_id: 9_999_998) do |record|
            record.github_installation = github_installation
            record.created_by = user
            record.name = "Screenshot Installation Project"
            record.owner = "paid"
            record.repo = "installation-screenshots"
            record.default_branch = "main"
            record.poll_interval_seconds = 60
            record.label_mappings = {}
            record.allowed_github_usernames = [ user.email ]
          end

          clarifying_issue = project.issues.find_or_create_by!(github_issue_id: 9_999_991) do |record|
            record.github_number = 1964
            record.title = "Answer issue clarifying questions via Paid UI wizard"
            record.body = <<~MARKDOWN
              <!-- paid:enhance-issue -->

              ## Clarifying questions
              1. What is the desired end-to-end behavior after the user submits answers?
              2. Should the wizard allow editing previous answers before submission?

              ## Current context
              - Waiting for a trusted collaborator to answer in the Paid UI.
            MARKDOWN
            record.github_creator_login = user.email
            record.github_state = "open"
            record.github_created_at = 1.day.ago
            record.github_updated_at = Time.current
            record.paid_state = "needs_input"
            record.labels = [ project.enhance_issue_needs_input_label_name ]
          end

          provider = user.runners.subscription.first!
          provider.update!(enabled_for_agent_runs: true, enabled_for_fallback: true)

          service_container = ServiceContainer.find_or_create_by!(account: account, name: "Screenshot Postgres") do |record|
            record.image = "postgres:16"
            record.port = 5432
            record.env = {}
            record.status = "stopped"
          end

          mcp_server_definition = McpServerDefinition.find_or_create_by!(account: account, name: "Screenshot MCP Server") do |record|
            record.transport = "stdio"
            record.install_type = "npx"
            record.command = "@modelcontextprotocol/server-filesystem"
          end

          agent_run = project.agent_runs.find_or_initialize_by(custom_prompt: "Capture screenshot route coverage")
          reset_agent_run!(agent_run) if agent_run.persisted?
          assign_agent_run_defaults!(agent_run)
          agent_run.save!

          prompt = Prompt.find_or_create_by!(account: account, slug: "screenshots.prompt") do |record|
            record.name = "Screenshots Prompt"
            record.category = "coding"
            record.active = true
          end

          current_prompt_version = prompt.current_version || prompt.create_version!(
            template: "Ship {{title}} safely",
            system_prompt: "You are a pragmatic coding assistant.",
            created_by: "screenshots",
            created_by_user: user,
            change_notes: "Initial screenshot seed"
          )

          pending_prompt_version = prompt.prompt_versions.pending_review.order(:id).first || prompt.create_pending_version!(
            template: "Ship {{title}} safely with extra review",
            system_prompt: "You are a pragmatic coding assistant.",
            created_by: "screenshots",
            created_by_user: user,
            change_notes: "Pending screenshot seed",
            parent_version: current_prompt_version
          )

          strategy = Strategy.find_or_create_by!(account: account, slug: "screenshots.strategy") do |record|
            record.name = "Screenshot Strategy"
            record.decision_type = "issue_execution"
            record.status = "active"
            record.selection_rules = {}
          end

          current_strategy_version = strategy.current_version || strategy.create_version!(
            content: { "mode" => "single" },
            provenance: { "source" => "screenshots_seed" },
            promotion_state: "active",
            created_by: "screenshots",
            created_by_user: user,
            promoted_at: Time.current,
            promoted_by_user: user,
            change_notes: "Initial screenshot strategy seed"
          ).tap { |version| strategy.update!(current_version: version) }

          pending_strategy_version = strategy.strategy_versions.pending_review.order(:id).first || strategy.create_pending_version!(
            content: { "mode" => "parallel" },
            provenance: { "source" => "screenshots_seed" },
            reasoning: "Increase parallel review coverage",
            change_notes: "Pending strategy review seed",
            created_by: "screenshots",
            created_by_user: user,
            parent_version: current_strategy_version
          )

          ab_test = prompt.ab_tests.where(name: "Screenshot A/B Test").first_or_create!(
            control_version: current_prompt_version,
            description: "Representative screenshot coverage",
            status: "draft",
            min_samples_per_variant: 30,
            confidence_threshold: 0.95
          )
          ab_test.ab_test_variants.find_or_create_by!(prompt_version: current_prompt_version) do |record|
            record.is_control = true
          end
          ab_test.ab_test_variants.find_or_create_by!(prompt_version: pending_prompt_version) do |record|
            record.is_control = false
          end

          provider_api_key = user.provider_api_keys.find_or_create_by!(name: "Screenshot OpenAI Key") do |record|
            record.api_service_type = "openai"
            record.api_key = "sk-test-#{'a' * 32}"
          end

          integration_credential = account.integration_credentials.find_or_create_by!(
            name: "Screenshot Claude Credential",
            service_key: "claude"
          ) do |record|
            record.created_by = user
            record.auth_kind = "api_key"
            record.secret = "sk-ant-#{'a' * 24}"
          end

          runner_credential = account.runner_credentials.find_or_create_by!(runner_key: provider.runner_key) do |record|
            record.created_by = user
            record.token = "sk-ant-oat01-#{'a' * 24}"
            record.long_lived = true
          end

          linear_token = account.linear_tokens.find_or_create_by!(name: "Screenshot Linear Token") do |record|
            record.created_by = user
            record.token = "lin_api_#{'a' * 32}"
            record.validation_status = "validated"
          end

          style_guide = StyleGuide.find_or_create_by!(project: project, name: "Screenshot Style Guide") do |record|
            record.account = account
            record.raw_content = "Prefer small methods and explicit tests."
            record.language = "ruby"
            record.active = true
          end

          marketplace_entry = account.marketplace_entries.find_or_create_by!(name: "Screenshot Catalog Entry") do |record|
            record.description = "Representative marketplace entry for screenshot capture coverage."
            record.entry_type = "workflow_strategy"
            record.provider = "openai"
            record.provider_format = "canonical_v1"
            record.usage_guidance = "Attach to runs that need a managed rollout workflow strategy."
            record.added_by_name = user.name.presence || "Screenshot User"
            record.added_by_email = user.email
            record.tags = [ "screenshots", "managed-platform" ]
            record.extension_points = [ "workflow_strategies", "prompts" ]
            record.certification_status = "verified"
            record.support_tier = "first_party"
            record.documentation_url = "https://docs.example.com/screenshots/catalog-entry"
            record.source_code_url = "https://github.com/example/screenshots-catalog-entry"
            record.certification_notes = "Seeded for screenshot coverage of marketplace entry detail and edit pages."
            record.team_scope = "account"
            record.status = "active"
          end
          marketplace_entry.current_version || marketplace_entry.create_version!(
            canonical_artifact: { "slug" => "screenshots.workflow_strategy", "entry_type" => "workflow_strategy" },
            renderers: { "default" => { "template" => "Use the managed rollout workflow strategy." } },
            compatibility_constraints: { "paid_version" => ">= 8.0" },
            review_metadata: { "certification_status" => "verified", "reviewed_by" => "screenshots" },
            changelog: "Initial screenshot seed version"
          )

          chat_session = ChatSession.where(account: account, title: "Screenshot Chat").first_or_create!(
            created_by: user,
            project: project,
            runner: provider,
            mode: "workspace",
            status: "active"
          )

          project_version = ProjectVersion.find_or_create_by!(project: project, commit_sha: "f" * 40) do |record|
            record.branch = "main"
            record.committed_at = 1.day.ago
          end

          collector_run = CollectorRun.find_or_create_by!(project_version: project_version, collector_type: "screenshot_seed") do |record|
            record.status = "completed"
            record.started_at = 5.minutes.ago
            record.completed_at = 4.minutes.ago
            record.duration_ms = 60_000
            record.artifacts_count = 1
          end

          knowledge_artifact = KnowledgeArtifact.find_or_create_by!(
            collector_run: collector_run,
            content_hash: Digest::SHA256.hexdigest("screenshots-seed-artifact")
          ) do |record|
            record.project = project
            record.collector_type = collector_run.collector_type
            record.artifact_type = "route"
            record.scope_path = "config/routes.rb"
            record.identifier = "GET /screenshots"
            record.content = "Screenshot artifact seed"
            record.metadata = { source: "screenshots_seed" }
            record.status = "active"
          end

          KnowledgeChunk.find_or_create_by!(knowledge_artifact: knowledge_artifact, sequence: 0) do |record|
            record.project = project
            record.chunk_type = "definition"
            record.status = "active"
            record.content = "Screenshot artifact chunk seed"
            record.content_hash = Digest::SHA256.hexdigest("screenshots-seed-artifact-chunk")
          end

          KnowledgeRecommendation.find_or_create_by!(project: project, description: "Add database_schema collector") do |record|
            record.recommendation_type = "add_collector"
            record.collector_type = "database_schema"
            record.priority = "high"
            record.status = "pending"
            record.evidence = { reason: "No schema artifacts found" }
          end

          KnowledgeRecommendation.find_or_create_by!(project: project, description: "Remove stale api_docs collector") do |record|
            record.recommendation_type = "remove_collector"
            record.collector_type = "api_docs"
            record.priority = "medium"
            record.status = "pending"
            record.evidence = { reason: "Collector has produced no artifacts in 30 days" }
          end

          diagnosis_attempted_at = Time.current
          remediation_decision = RemediationDecision.find_or_create_by!(account: account, fingerprint: "screenshots-remediation-fingerprint") do |record|
            record.root_cause = "Runner fallback exhausted after repeated GitHub API rate limits"
            record.confidence = 0.88
            record.evidence_pointers = [ "runner_attempts[0].error_message" ]
            record.proposed_action = "disable_runner_fallback"
            record.action_target_type = "runner"
            record.action_target_id = provider.id.to_s
            record.action_target_metadata = {}
            record.status = "proposed"
            record.revert_data = {}
            record.pre_remediation_failure_count = 3
            record.occurrence_count = 1
            record.diagnosis_attempted_on = diagnosis_attempted_at.to_date
            record.diagnosis_attempt_count_on_day = 1
            record.last_diagnosis_attempt_at = diagnosis_attempted_at
          end

          WorkflowState.find_or_create_by!(temporal_workflow_id: "github-poll-#{project.id}") do |record|
            record.project = project
            record.workflow_type = "GitHubPollWorkflow"
            record.status = "running"
            record.started_at = 1.hour.ago
          end

          {
            "user" => { "id" => user.id, "email" => user.email, "password" => password },
            "project" => { "id" => project.id, "name" => project.name, "slug" => project.repo },
            "clarifying_issue" => { "id" => clarifying_issue.id, "github_number" => clarifying_issue.github_number },
            "runner" => { "id" => provider.id, "name" => provider.display_name },
            "github_installation" => { "id" => github_installation.id, "account_login" => github_installation.account_login },
            "github_token" => { "id" => github_token.id, "name" => github_token.name },
            "integration_credential" => { "id" => integration_credential.id, "name" => integration_credential.name },
            "runner_credential" => { "id" => runner_credential.id },
            "linear_token" => { "id" => linear_token.id, "name" => linear_token.name },
            "provider_api_key" => { "id" => provider_api_key.id, "name" => provider_api_key.name },
            "service_container" => { "id" => service_container.id, "name" => service_container.name },
            "mcp_server_definition" => { "id" => mcp_server_definition.id, "name" => mcp_server_definition.name },
            "agent_run" => { "id" => agent_run.id },
            "prompt" => { "id" => prompt.id, "name" => prompt.name },
            "pending_prompt_version" => { "id" => pending_prompt_version.id },
            "strategy" => { "id" => strategy.id, "name" => strategy.name },
            "pending_strategy_version" => { "id" => pending_strategy_version.id },
            "ab_test" => { "id" => ab_test.id },
            "style_guide" => { "id" => style_guide.id, "name" => style_guide.name },
            "marketplace_entry" => { "id" => marketplace_entry.id, "name" => marketplace_entry.name },
            "chat_session" => { "id" => chat_session.id, "name" => chat_session.title },
            "knowledge_artifact" => { "id" => knowledge_artifact.id },
            "remediation_decision" => { "id" => remediation_decision.id },
            "installation_project" => { "id" => installation_project.id, "name" => installation_project.name }
          }
        end

        private

        def reset_agent_run!(agent_run)
          agent_run.agent_run_logs.destroy_all
          agent_run.agent_run_phases.destroy_all
          agent_run.quality_metrics.destroy_all
          agent_run.model_selection&.destroy
          agent_run.created_at = Time.current
        end

        def assign_agent_run_defaults!(agent_run)
          agent_run.assign_attributes(
            agent_type: "codex", goal: "create_pr", status: "queued",
            issue_id: nil, source_pull_request_number: nil,
            temporal_workflow_id: nil, temporal_run_id: nil,
            started_at: nil, completed_at: nil, duration_seconds: nil,
            container_id: nil, service_container_ids: [],
            error_message: nil, pull_request_url: nil, pull_request_number: nil,
            created_issue_url: nil, created_issue_number: nil,
            review_url: nil, review_posted_at: nil,
            result_commit_sha: nil, base_commit_sha: nil,
            worktree_path: nil, branch_name: nil,
            runner_id: nil,
            runners_attempted: [], final_runner: nil, runner_switches: 0,
            iterations: 0, cost_cents: 0,
            tokens_input: 0, tokens_output: 0,
            trigger_type: "automatic",
            token_limit_status: nil, cross_repo_issues: []
          )
        end
      end
    end
  end
end
