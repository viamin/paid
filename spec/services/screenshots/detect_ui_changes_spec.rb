# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::DetectUiChanges do
  describe ".call" do
    it "detects ERB view changes" do
      result = described_class.call(changed_files: [ "app/views/projects/index.html.erb" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/views/projects/index.html.erb" ])
    end

    it "detects JavaScript file changes" do
      result = described_class.call(changed_files: [ "app/javascript/controllers/dashboard_controller.js" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/javascript/controllers/dashboard_controller.js" ])
    end

    it "detects CSS/SCSS file changes" do
      result = described_class.call(changed_files: [ "app/assets/stylesheets/application.css" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/assets/stylesheets/application.css" ])
    end

    it "detects view helper changes" do
      result = described_class.call(changed_files: [ "app/helpers/application_helper.rb" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/helpers/application_helper.rb" ])
    end

    it "detects TypeScript/TSX changes" do
      result = described_class.call(changed_files: [ "app/frontend/components/Button.tsx" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/frontend/components/Button.tsx" ])
    end

    it "ignores non-UI files" do
      result = described_class.call(changed_files: [
        "app/models/project.rb",
        "app/services/agent_runs/create.rb",
        "spec/models/project_spec.rb",
        "config/routes.rb",
        "db/migrate/20260101000000_create_projects.rb"
      ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "ignores frontend-looking extensions outside UI directories" do
      result = described_class.call(changed_files: [
        "spec/fixtures/knowledge/sample.ts",
        "script/build.js",
        "vendor/assets/theme.css"
      ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "returns only UI files from a mixed set" do
      changed_files = [
        "app/models/project.rb",
        "app/views/projects/show.html.erb",
        "app/services/agent_runs/create.rb",
        "app/javascript/controllers/modal_controller.js",
        "spec/models/project_spec.rb"
      ]

      result = described_class.call(changed_files: changed_files)

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to contain_exactly(
        "app/views/projects/show.html.erb",
        "app/javascript/controllers/modal_controller.js"
      )
    end

    it "handles empty file list" do
      result = described_class.call(changed_files: [])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "handles nil changed_files gracefully" do
      result = described_class.call(changed_files: nil)

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "detects SCSS stylesheet changes" do
      result = described_class.call(changed_files: [ "app/assets/stylesheets/components/_buttons.scss" ])

      expect(result[:ui_changes?]).to be true
    end

    it "detects component directory changes" do
      result = described_class.call(changed_files: [ "app/components/sidebar_component.rb" ])

      expect(result[:ui_changes?]).to be true
    end

    it "detects asset build output changes" do
      result = described_class.call(changed_files: [ "app/assets/builds/application.css" ])

      expect(result[:ui_changes?]).to be true
    end

    it "detects locale file changes" do
      result = described_class.call(changed_files: [ "config/locales/devise.en.yml" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "config/locales/devise.en.yml" ])
    end

    it "ignores mailer templates that do not render browser UI" do
      result = described_class.call(changed_files: [ "app/views/devise/mailer/reset_password_instructions.html.erb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "ignores pwa templates that do not map to rendered screenshots" do
      result = described_class.call(changed_files: [ "app/views/pwa/manifest.json.erb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "detects controller changes that affect rendered pages" do
      result = described_class.call(changed_files: [ "app/controllers/dashboard_controller.rb" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/controllers/dashboard_controller.rb" ])
    end

    it "ignores API controllers that do not render HTML" do
      result = described_class.call(changed_files: [ "app/controllers/api/secrets_proxy_controller.rb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "ignores controller concerns" do
      result = described_class.call(changed_files: [ "app/controllers/concerns/agent_run_cancellable.rb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "detects static browser-facing asset changes" do
      result = described_class.call(changed_files: [ "public/icon.svg" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "public/icon.svg" ])
    end

    it "ignores non-visual public files" do
      result = described_class.call(changed_files: [ "public/robots.txt", "public/404.html" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end
  end
end
