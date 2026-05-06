# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::DetectFramework do
  describe ".call" do
    context "with file_list" do
      it "detects Rails from config/routes.rb and app/views" do
        file_list = [ "config/routes.rb", "app/views/home/index.html.erb", "Gemfile" ]

        expect(described_class.call(file_list: file_list)).to eq(:rails)
      end

      it "detects Next.js from next.config.js and app directory" do
        file_list = [ "next.config.js", "app/page.tsx", "package.json" ]

        expect(described_class.call(file_list: file_list)).to eq(:nextjs)
      end

      it "detects Next.js from next.config.ts" do
        file_list = [ "next.config.ts", "pages/index.tsx" ]

        expect(described_class.call(file_list: file_list)).to eq(:nextjs)
      end

      it "detects Next.js from next.config.mjs" do
        file_list = [ "next.config.mjs", "app/layout.tsx" ]

        expect(described_class.call(file_list: file_list)).to eq(:nextjs)
      end

      it "detects Next.js from next.config.js and src/app" do
        file_list = [ "next.config.js", "src/app/page.tsx", "package.json" ]

        expect(described_class.call(file_list: file_list)).to eq(:nextjs)
      end

      it "detects Next.js from next.config.ts and src/pages" do
        file_list = [ "next.config.ts", "src/pages/index.tsx", "package.json" ]

        expect(described_class.call(file_list: file_list)).to eq(:nextjs)
      end

      it "detects Django from manage.py and templates" do
        file_list = [ "manage.py", "myapp/templates/home.html", "requirements.txt" ]

        expect(described_class.call(file_list: file_list)).to eq(:django)
      end

      it "falls back to generic when no framework detected" do
        file_list = [ "index.html", "styles.css", "app.js" ]

        expect(described_class.call(file_list: file_list)).to eq(:generic)
      end

      it "falls back to generic for empty file list" do
        expect(described_class.call(file_list: [])).to eq(:generic)
      end

      it "prefers Rails when both Rails and Django markers are present" do
        file_list = [ "config/routes.rb", "app/views/home/index.html.erb", "manage.py", "templates/base.html" ]

        expect(described_class.call(file_list: file_list)).to eq(:rails)
      end

      it "requires both markers for Rails detection" do
        file_list = [ "config/routes.rb", "Gemfile" ]

        expect(described_class.call(file_list: file_list)).to eq(:generic)
      end

      it "requires both markers for Next.js detection" do
        file_list = [ "app/page.tsx", "package.json" ]

        expect(described_class.call(file_list: file_list)).to eq(:generic)
      end

      it "requires both markers for Django detection" do
        file_list = [ "manage.py", "requirements.txt" ]

        expect(described_class.call(file_list: file_list)).to eq(:generic)
      end
    end

    context "with repo_path" do
      let(:repo_path) { Dir.mktmpdir }

      after { FileUtils.remove_entry(repo_path) }

      it "detects Rails from filesystem" do
        FileUtils.mkdir_p(File.join(repo_path, "app/views"))
        FileUtils.mkdir_p(File.join(repo_path, "config"))
        File.write(File.join(repo_path, "config/routes.rb"), "# routes")

        expect(described_class.call(repo_path: repo_path)).to eq(:rails)
      end

      it "falls back to generic when repo has no framework markers" do
        File.write(File.join(repo_path, "README.md"), "# Hello")

        expect(described_class.call(repo_path: repo_path)).to eq(:generic)
      end

      it "detects Next.js src/app layout from filesystem" do
        FileUtils.mkdir_p(File.join(repo_path, "src/app"))
        File.write(File.join(repo_path, "next.config.js"), "export default {}")
        File.write(File.join(repo_path, "src/app/page.tsx"), "export default function Page() {}")

        expect(described_class.call(repo_path: repo_path)).to eq(:nextjs)
      end
    end

    context "with no arguments" do
      it "falls back to generic" do
        expect(described_class.call).to eq(:generic)
      end
    end
  end
end
