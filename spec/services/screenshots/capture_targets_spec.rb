# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::CaptureTargets, :no_db do
  describe ".call" do
    it "maps locale changes to shared UI targets" do
      targets = described_class.call(changed_files: [ "config/locales/devise.en.yml" ])

      expect(targets.map(&:slug)).to include("sign_in", "dashboard", "projects")
    end

    it "maps project-scoped views to project-specific routes" do
      targets = described_class.call(changed_files: [ "app/views/projects/quality_dashboards/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_quality_dashboard" ])
    end

    it "maps resource edit screens to representative edit routes" do
      targets = described_class.call(changed_files: [ "app/views/service_containers/edit.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "service_container_edit" ])
    end

    it "maps GitHub App views to their dedicated screenshot targets" do
      expect(described_class.call(changed_files: [ "app/views/github_installations/index.html.erb" ]).map(&:slug))
        .to eq([ "github_installations" ])
      expect(described_class.call(changed_files: [ "app/views/github_installations/show.html.erb" ]).map(&:slug))
        .to eq([ "github_installation_show" ])
      expect(described_class.call(changed_files: [ "app/views/github_installations/migrate_projects.html.erb" ]).map(&:slug))
        .to eq([ "github_installation_migrate_projects" ])
    end

    it "maps marketplace entry views to their specific screenshot targets" do
      expect(described_class.call(changed_files: [ "app/views/marketplace_entries/index.html.erb" ]).map(&:slug))
        .to eq([ "marketplace_entries" ])
      expect(described_class.call(changed_files: [ "app/views/marketplace_entries/show.html.erb" ]).map(&:slug))
        .to eq([ "marketplace_entry_show" ])
      expect(described_class.call(changed_files: [ "app/views/marketplace_entries/edit.html.erb" ]).map(&:slug))
        .to eq([ "marketplace_entry_edit" ])
      expect(described_class.call(changed_files: [ "app/views/marketplace_entries/_form.html.erb" ]).map(&:slug))
        .to contain_exactly("marketplace_entry_new", "marketplace_entry_edit")
    end

    it "maps existing prompt review screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/prompt_reviews/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "prompt_review_show" ])
    end

    it "maps strategy review screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/strategy_reviews/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "strategy_review_show" ])
    end

    it "maps existing knowledge screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/knowledge/search/project_search.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_knowledge_search" ])
    end

    it "maps helper files that do not follow the default helper-to-view naming convention" do
      targets = described_class.call(changed_files: [ "app/helpers/workflow_helper.rb" ])

      expect(targets.map(&:slug)).to eq([ "workflow_status" ])
    end

    it "maps ROI helper changes to the ROI dashboard screenshot targets" do
      targets = described_class.call(changed_files: [ "app/helpers/roi_dashboard_helper.rb" ])

      expect(targets.map(&:slug)).to contain_exactly("account_roi_dashboard", "project_roi_dashboard")
    end

    it "maps operations dashboard views to the dedicated account operations target" do
      targets = described_class.call(changed_files: [ "app/views/accounts/operations_dashboards/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "account_operations_dashboard" ])
    end

    it "maps component files to shared UI targets" do
      targets = described_class.call(changed_files: [ "app/components/sidebar_component.rb" ])

      expect(targets.map(&:slug)).to include("sign_in", "dashboard", "projects")
    end

    it "does not add strategy review pages to the generic shared capture set" do
      targets = described_class.call(changed_files: [ "app/components/sidebar_component.rb" ])

      expect(targets.map(&:slug)).not_to include("strategy_reviews_queue", "strategy_reviews", "strategy_review_show")
    end

    it "maps knowledge artifact views to the artifact show route" do
      targets = described_class.call(changed_files: [ "app/views/knowledge/artifacts/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_knowledge_artifact_show" ])
    end

    it "maps controller files to their corresponding page targets" do
      targets = described_class.call(changed_files: [ "app/controllers/dashboard_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "dashboard" ])
    end

    it "maps the legacy providers controller to runner screenshot targets during the rename tail" do
      targets = described_class.call(changed_files: [ "app/controllers/providers_controller.rb" ])

      expect(targets.map(&:slug)).to contain_exactly("providers", "providers_new", "providers_edit")
    end

    it "maps account administration controllers to the account page target" do
      targets = described_class.call(changed_files: [ "app/controllers/accounts_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "account" ])
    end

    it "maps the account audit log controller to the audit log target" do
      targets = described_class.call(changed_files: [ "app/controllers/account_audit_logs_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "account_audit_logs" ])
    end

    it "maps remediation decision views to the remediation decision screenshot target" do
      targets = described_class.call(changed_files: [ "app/views/remediation_decisions/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "remediation_decision_show" ])
    end

    it "maps marketplace entry controllers to representative marketplace routes" do
      targets = described_class.call(changed_files: [ "app/controllers/marketplace_entries_controller.rb" ])

      expect(targets.map(&:slug)).to contain_exactly(
        "marketplace_entries",
        "marketplace_entry_new",
        "marketplace_entry_show",
        "marketplace_entry_edit"
      )
    end

    it "maps the GitHub App controller to its representative pages" do
      targets = described_class.call(changed_files: [ "app/controllers/github_installations_controller.rb" ])

      expect(targets.map(&:slug)).to contain_exactly(
        "github_installations",
        "github_installation_show",
        "github_installation_migrate_projects"
      )
    end

    it "maps nested controller files to their corresponding page targets" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/cost_dashboards_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_cost_dashboard" ])
    end

    it "maps the clarifying-questions wizard controller to its screenshot target" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/clarifying_questions_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_issue_clarifying_questions" ])
    end

    it "maps the clarifying-questions Stimulus controller to its screenshot target" do
      targets = described_class.call(changed_files: [ "app/javascript/controllers/clarifying_questions_controller.js" ])

      expect(targets.map(&:slug)).to eq([ "project_issue_clarifying_questions" ])
    end

    it "maps the marketplace picker Stimulus controller to the project run form" do
      targets = described_class.call(changed_files: [ "app/javascript/controllers/marketplace_picker_controller.js" ])

      expect(targets.map(&:slug)).to eq([ "project_agent_run_new" ])
    end

    it "does not broaden screenshot capture when the controller registry changes alongside a mapped Stimulus controller" do
      targets = described_class.call(
        changed_files: [
          "app/javascript/controllers/index.js",
          "app/javascript/controllers/clarifying_questions_controller.js"
        ]
      )

      expect(targets.map(&:slug)).to eq([ "project_issue_clarifying_questions" ])
    end

    it "maps projects/agent_runs_controller to include the new action target" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/agent_runs_controller.rb" ])

      expect(targets.map(&:slug)).to contain_exactly(
        "project_agent_runs",
        "project_agent_run_new",
        "project_agent_run_show",
        "project_agent_run_provenance"
      )
    end

    it "maps the project run form and run detail partials to the relevant project agent run pages" do
      expect(described_class.call(changed_files: [ "app/views/projects/agent_runs/new.html.erb" ]).map(&:slug))
        .to eq([ "project_agent_run_new" ])
      expect(described_class.call(changed_files: [ "app/views/agent_runs/_detail.html.erb" ]).map(&:slug))
        .to eq([ "project_agent_run_show" ])
    end

    it "maps the new project run provenance view to its screenshot target" do
      targets = described_class.call(changed_files: [ "app/views/projects/agent_runs/provenance.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_agent_run_provenance" ])
    end

    it "maps public assets to shared UI targets" do
      targets = described_class.call(changed_files: [ "public/icon.png" ])

      expect(targets.map(&:slug)).to eq([ "public_icon_png" ])
    end

    it "maps view partials to both new and edit targets" do
      targets = described_class.call(changed_files: [ "app/views/service_containers/_form.html.erb" ])

      expect(targets.map(&:slug)).to contain_exactly("service_container_new", "service_container_edit")
    end

    it "maps free models catalog view to free_models_catalog target" do
      targets = described_class.call(changed_files: [ "app/views/free_models/index.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "free_models_catalog" ])
    end

    it "maps integrations new view to integrations_new target" do
      targets = described_class.call(changed_files: [ "app/views/integrations/new.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "integrations_new" ])
    end

    it "maps prompt views to their specific targets" do
      targets = described_class.call(changed_files: [ "app/views/prompts/new.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "prompt_new" ])

      targets = described_class.call(changed_files: [ "app/views/prompts/show.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "prompt_show" ])

      targets = described_class.call(changed_files: [ "app/views/prompts/edit.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "prompt_edit" ])

      targets = described_class.call(changed_files: [ "app/views/prompts/diff.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "prompt_diff" ])
    end

    it "maps prompt partials to new and edit targets" do
      targets = described_class.call(changed_files: [ "app/views/prompts/_form.html.erb" ])

      expect(targets.map(&:slug)).to contain_exactly("prompt_new", "prompt_edit")
    end

    it "maps controller with new/edit actions to include those targets" do
      targets = described_class.call(changed_files: [ "app/controllers/provider_api_keys_controller.rb" ])

      slugs = targets.map(&:slug)
      expect(slugs).to include("provider_api_key_new", "provider_api_key_edit")
    end

    it "maps shared targets to include chat and ab_test pages" do
      targets = described_class.call(changed_files: [ "app/javascript/controllers/modal_controller.js" ])

      slugs = targets.map(&:slug)
      expect(slugs).to include("chat_sessions", "ab_tests", "style_guides", "knowledge_search")
    end

    it "maps Devise registration views to sign_up target" do
      targets = described_class.call(changed_files: [ "app/views/devise/registrations/new.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "sign_up" ])
    end

    it "maps Devise password views to forgot_password target" do
      targets = described_class.call(changed_files: [ "app/views/devise/passwords/new.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "forgot_password" ])
    end

    it "maps Devise confirmation views to confirmation target" do
      targets = described_class.call(changed_files: [ "app/views/devise/confirmations/new.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "confirmation" ])
    end

    it "maps Devise shared partials to all auth targets" do
      targets = described_class.call(changed_files: [ "app/views/devise/shared/_links.html.erb" ])

      expect(targets.map(&:slug)).to contain_exactly(
        "sign_in", "sign_up", "forgot_password", "confirmation", "unlock"
      )
    end

    it "maps project show partials to project_show target" do
      targets = described_class.call(changed_files: [ "app/views/projects/_issues.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_show" ])
    end

    it "maps the issue pause toggle partial to the project_show target" do
      targets = described_class.call(changed_files: [ "app/views/projects/_issue_pause_toggle.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_show" ])
    end

    it "maps the account administration view to the account page target" do
      targets = described_class.call(changed_files: [ "app/views/accounts/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "account" ])
    end

    it "maps the account audit log view to the audit log target" do
      targets = described_class.call(changed_files: [ "app/views/account_audit_logs/index.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "account_audit_logs" ])
    end

    it "maps the clarifying-questions wizard view to its screenshot target" do
      targets = described_class.call(changed_files: [ "app/views/projects/clarifying_questions/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_issue_clarifying_questions" ])
    end

    it "maps project index partials to projects target" do
      targets = described_class.call(changed_files: [ "app/views/projects/_auto_pick_toggle_index.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "projects" ])
    end

    it "maps runner index partials to the runners screenshot target" do
      targets = described_class.call(changed_files: [ "app/views/runners/_settings.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "providers" ])

      targets = described_class.call(changed_files: [ "app/views/runners/_usage_stats.html.erb" ])
      expect(targets.map(&:slug)).to eq([ "providers" ])
    end

    it "raises UnmappedUiChangeError for unmapped controllers" do
      expect {
        described_class.call(changed_files: [ "app/controllers/unknown_controller.rb" ])
      }.to raise_error(described_class::UnmappedUiChangeError)
    end

    it "maps nested project controllers to their redirect targets" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/service_containers_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_edit" ])
    end

    it "maps the issues toggle_pause controller to the project_show target" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/issues_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_show" ])
    end

    it "maps convention settings controller to the convention settings page" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/convention_settings_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_convention_settings" ])
    end

    it "maps projects controller to include project_new target" do
      targets = described_class.call(changed_files: [ "app/controllers/projects_controller.rb" ])

      expect(targets.map(&:slug)).to include("project_new")
    end

    it "maps prompts controller to include prompt_diff target" do
      targets = described_class.call(changed_files: [ "app/controllers/prompts_controller.rb" ])

      expect(targets.map(&:slug)).to include("prompt_diff")
    end

    it "maps public HTML error pages to shared UI targets" do
      targets = described_class.call(changed_files: [ "public/404.html" ])

      expect(targets.map(&:slug)).to eq([ "public_404" ])
    end

    it "maps application_controller to representative authenticated pages" do
      targets = described_class.call(changed_files: [ "app/controllers/application_controller.rb" ])

      expect(targets.map(&:slug)).to include("dashboard", "projects", "providers")
      expect(targets.map(&:slug)).not_to include("sign_in")
    end

    it "maps the custom Devise registrations controller to the sign-up page" do
      targets = described_class.call(changed_files: [ "app/controllers/users/registrations_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "sign_up" ])
    end

    it "covers every current non-api controller that detect_ui_changes can surface" do
      controller_paths = Dir[Rails.root.join("app/controllers/**/*_controller.rb")]
        .map { |path| path.delete_prefix("#{Rails.root}/") }
        .reject do |path|
          path.include?("/api/") ||
            path.include?("/concerns/") ||
            path.end_with?("health_controller.rb") ||
            path.end_with?("operator_console_access_controller.rb")
        end

      expect {
        described_class.call(changed_files: controller_paths)
      }.not_to raise_error
    end
  end
end
