# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::FrameworkPatterns do
  describe ".for" do
    it "returns Rails patterns" do
      result = described_class.for(:rails)

      expect(result[:patterns]).to be_an(Array)
      expect(result[:patterns]).not_to be_empty
      expect(result[:exclusions]).to be_an(Array)
    end

    it "returns Next.js patterns" do
      result = described_class.for(:nextjs)

      expect(result[:patterns]).to be_an(Array)
      expect(result[:patterns]).not_to be_empty
    end

    it "returns Django patterns" do
      result = described_class.for(:django)

      expect(result[:patterns]).to be_an(Array)
      expect(result[:patterns]).not_to be_empty
    end

    it "returns Phoenix patterns" do
      result = described_class.for(:phoenix)

      expect(result[:patterns]).to be_an(Array)
      expect(result[:patterns]).not_to be_empty
    end

    it "returns generic patterns" do
      result = described_class.for(:generic)

      expect(result[:patterns]).to be_an(Array)
      expect(result[:patterns]).not_to be_empty
    end

    it "raises for unknown framework" do
      expect { described_class.for(:unknown) }.to raise_error(ArgumentError, /Unknown framework/)
    end
  end

  describe "Rails patterns" do
    let(:patterns) { described_class.for(:rails) }

    it "matches ERB views" do
      expect(patterns[:patterns].any? { |p| p.match?("app/views/projects/index.html.erb") }).to be true
    end

    it "matches JavaScript controllers" do
      expect(patterns[:patterns].any? { |p| p.match?("app/javascript/controllers/modal_controller.js") }).to be true
    end

    it "excludes mailer templates" do
      expect(patterns[:exclusions].any? { |p| p.match?("app/views/devise/mailer/reset_password_instructions.html.erb") }).to be true
    end
  end

  describe "Next.js patterns" do
    let(:patterns) { described_class.for(:nextjs) }

    it "matches page components" do
      expect(patterns[:patterns].any? { |p| p.match?("app/dashboard/page.tsx") }).to be true
    end

    it "matches root-level page component" do
      expect(patterns[:patterns].any? { |p| p.match?("app/page.tsx") }).to be true
    end

    it "matches layout components" do
      expect(patterns[:patterns].any? { |p| p.match?("app/dashboard/layout.tsx") }).to be true
    end

    it "matches root-level layout component" do
      expect(patterns[:patterns].any? { |p| p.match?("app/layout.tsx") }).to be true
    end

    it "matches app router global stylesheets" do
      expect(patterns[:patterns].any? { |p| p.match?("app/globals.css") }).to be true
    end

    it "matches app router CSS modules" do
      expect(patterns[:patterns].any? { |p| p.match?("app/dashboard/page.module.css") }).to be true
    end

    it "matches component files" do
      expect(patterns[:patterns].any? { |p| p.match?("components/Button.tsx") }).to be true
    end

    it "matches src directory components" do
      expect(patterns[:patterns].any? { |p| p.match?("src/components/Header.tsx") }).to be true
    end

    it "matches src/pages routes" do
      expect(patterns[:patterns].any? { |p| p.match?("src/pages/index.tsx") }).to be true
    end

    it "excludes pages router API routes" do
      expect(patterns[:exclusions].any? { |p| p.match?("pages/api/users.ts") }).to be true
      expect(patterns[:exclusions].any? { |p| p.match?("src/pages/api/auth/[...nextauth].ts") }).to be true
    end

    it "excludes app router API routes" do
      expect(patterns[:exclusions].any? { |p| p.match?("app/api/auth/[...nextauth]/route.ts") }).to be true
      expect(patterns[:exclusions].any? { |p| p.match?("src/app/api/users/route.ts") }).to be true
    end
  end

  describe "generic patterns" do
    let(:patterns) { described_class.for(:generic) }

    it "matches HTML files" do
      expect(patterns[:patterns].any? { |p| p.match?("index.html") }).to be true
    end

    it "matches Vue single-file components" do
      expect(patterns[:patterns].any? { |p| p.match?("src/App.vue") }).to be true
    end

    it "matches Svelte components" do
      expect(patterns[:patterns].any? { |p| p.match?("src/routes/+page.svelte") }).to be true
    end
  end

  describe "Phoenix patterns" do
    let(:patterns) { described_class.for(:phoenix) }

    it "matches LiveView modules" do
      expect(patterns[:patterns].any? { |p| p.match?("lib/color_matching_web/live/match_live.ex") }).to be true
    end

    it "matches Phoenix assets" do
      expect(patterns[:patterns].any? { |p| p.match?("assets/js/app.js") }).to be true
      expect(patterns[:patterns].any? { |p| p.match?("assets/css/app.css") }).to be true
    end
  end
end
