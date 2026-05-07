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

    it "detects application locale file changes" do
      result = described_class.call(changed_files: [ "config/locales/en.yml" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "config/locales/en.yml" ])
    end

    it "excludes devise locale files (mixed mailer and browser strings)" do
      result = described_class.call(changed_files: [ "config/locales/devise.en.yml" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "excludes the health controller (infrastructure only, no browser UI)" do
      result = described_class.call(changed_files: [ "app/controllers/health_controller.rb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "ignores mailer templates that do not render browser UI" do
      result = described_class.call(changed_files: [ "app/views/devise/mailer/reset_password_instructions.html.erb" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "ignores mailer layout files (both HTML and text variants)" do
      result = described_class.call(changed_files: [
        "app/views/layouts/mailer.html.erb",
        "app/views/layouts/mailer.text.erb"
      ])

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
      result = described_class.call(changed_files: [ "public/robots.txt" ])

      expect(result[:ui_changes?]).to be false
      expect(result[:ui_files]).to be_empty
    end

    it "detects public HTML error pages as UI changes" do
      result = described_class.call(changed_files: [ "public/404.html", "public/500.html" ])

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to contain_exactly("public/404.html", "public/500.html")
    end
  end

  describe "framework-aware detection" do
    it "auto-detects framework from working directory when no framework specified" do
      # This repo is a Rails app, so auto-detection from Dir.pwd should find Rails patterns
      result = described_class.call(changed_files: [ "app/views/projects/index.html.erb" ])

      expect(result[:ui_changes?]).to be true
    end

    it "detects Next.js page changes with framework: :nextjs" do
      result = described_class.call(
        changed_files: [ "app/dashboard/page.tsx" ],
        framework: :nextjs
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/dashboard/page.tsx" ])
    end

    it "detects Next.js component changes" do
      result = described_class.call(
        changed_files: [ "components/Button.tsx" ],
        framework: :nextjs
      )

      expect(result[:ui_changes?]).to be true
    end

    it "detects Next.js src/pages changes" do
      result = described_class.call(
        changed_files: [ "src/pages/index.tsx" ],
        framework: :nextjs
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "src/pages/index.tsx" ])
    end

    it "detects Next.js app router stylesheet changes" do
      result = described_class.call(
        changed_files: [ "app/dashboard/page.module.css", "app/globals.css" ],
        framework: :nextjs
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to contain_exactly("app/dashboard/page.module.css", "app/globals.css")
    end

    it "ignores Rails-specific files with Next.js framework" do
      result = described_class.call(
        changed_files: [ "app/helpers/application_helper.rb" ],
        framework: :nextjs
      )

      expect(result[:ui_changes?]).to be false
    end

    it "detects Django template changes" do
      result = described_class.call(
        changed_files: [ "templates/home.html" ],
        framework: :django
      )

      expect(result[:ui_changes?]).to be true
    end

    it "detects generic web file changes" do
      result = described_class.call(
        changed_files: [ "src/App.vue", "styles/main.scss" ],
        framework: :generic
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to contain_exactly("src/App.vue", "styles/main.scss")
    end
  end

  describe "custom patterns" do
    it "accepts glob string patterns from screenshots config" do
      result = described_class.call(
        changed_files: [ "app/views/projects/index.html.erb", "app/models/project.rb" ],
        patterns: [ "app/views/**/*" ]
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/views/projects/index.html.erb" ])
    end

    it "applies glob string exclusions from screenshots config" do
      result = described_class.call(
        changed_files: [ "app/views/projects/index.html.erb", "app/views/layouts/mailer/reset.html.erb" ],
        patterns: [ "app/views/**/*" ],
        exclusions: [ "app/views/layouts/mailer/**/*" ]
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/views/projects/index.html.erb" ])
    end

    it "uses provided patterns instead of framework defaults" do
      result = described_class.call(
        changed_files: [ "my_custom/views/home.html" ],
        patterns: [ %r{\Amy_custom/views/} ]
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "my_custom/views/home.html" ])
    end

    it "applies custom exclusions" do
      result = described_class.call(
        changed_files: [ "my_custom/views/home.html", "my_custom/views/admin/secret.html" ],
        patterns: [ %r{\Amy_custom/views/} ],
        exclusions: [ %r{\Amy_custom/views/admin/} ]
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "my_custom/views/home.html" ])
    end

    it "applies custom exclusions on top of detected framework defaults" do
      result = described_class.call(
        changed_files: [ "app/views/projects/index.html.erb", "app/views/pwa/manifest.json.erb" ],
        exclusions: [ "app/views/pwa/**/*" ],
        repo_path: Dir.pwd
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/views/projects/index.html.erb" ])
    end

    it "preserves framework exclusions when custom exclusions are provided" do
      result = described_class.call(
        changed_files: [
          "app/views/projects/index.html.erb",
          "app/views/devise/mailer/reset_password_instructions.html.erb"
        ],
        framework: :rails,
        exclusions: [ "app/views/pwa/**/*" ]
      )

      expect(result[:ui_changes?]).to be true
      expect(result[:ui_files]).to eq([ "app/views/projects/index.html.erb" ])
    end

    it "custom patterns override framework when both provided" do
      result = described_class.call(
        changed_files: [ "app/views/projects/index.html.erb" ],
        framework: :rails,
        patterns: [ %r{\Acustom_only/} ]
      )

      expect(result[:ui_changes?]).to be false
    end
  end
end
