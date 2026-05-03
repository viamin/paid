# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::CaptureTargets do
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

    it "maps existing prompt review screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/prompt_reviews/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "prompt_review_show" ])
    end

    it "maps existing knowledge screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/knowledge/search/project_search.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_knowledge_search" ])
    end

    it "maps helper files that do not follow the default helper-to-view naming convention" do
      targets = described_class.call(changed_files: [ "app/helpers/workflow_helper.rb" ])

      expect(targets.map(&:slug)).to eq([ "workflow_status" ])
    end

    it "maps component files to shared UI targets" do
      targets = described_class.call(changed_files: [ "app/components/sidebar_component.rb" ])

      expect(targets.map(&:slug)).to include("sign_in", "dashboard", "projects")
    end

    it "maps knowledge artifact views to the artifact show route" do
      targets = described_class.call(changed_files: [ "app/views/knowledge/artifacts/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_knowledge_artifact_show" ])
    end

    it "maps controller files to their corresponding page targets" do
      targets = described_class.call(changed_files: [ "app/controllers/dashboard_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "dashboard" ])
    end

    it "maps nested controller files to their corresponding page targets" do
      targets = described_class.call(changed_files: [ "app/controllers/projects/cost_dashboards_controller.rb" ])

      expect(targets.map(&:slug)).to eq([ "project_cost_dashboard" ])
    end

    it "maps public assets to shared UI targets" do
      targets = described_class.call(changed_files: [ "public/icon.png" ])

      expect(targets.map(&:slug)).to include("sign_in", "dashboard", "projects")
    end

    it "maps view partials to both new and edit targets" do
      targets = described_class.call(changed_files: [ "app/views/service_containers/_form.html.erb" ])

      expect(targets.map(&:slug)).to contain_exactly("service_container_new", "service_container_edit")
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
  end
end
