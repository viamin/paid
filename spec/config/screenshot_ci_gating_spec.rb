# frozen_string_literal: true

require "spec_helper"
require "psych"
require "webmock/rspec"
require "tempfile"
require "pathname"
require_relative "../../app/services/screenshots/detect_ui_changes"

class ScreenshotCiGating < Pathname
end

RSpec.describe ScreenshotCiGating, :no_db do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:capture) { Psych.safe_load_file("#{root}/.github/workflows/pr-screenshots.yml") }
  let(:publish) { Psych.safe_load_file("#{root}/.github/workflows/pr-screenshots-publish.yml") }
  let(:repo_url) { "https://api.github.com/repos/viamin/paid" }

  let(:example_paths) do
    %w[
      app/views/projects/show.html.erb app/javascript/controllers/example.js
      app/assets/stylesheets/app.css app/assets/builds/app.css app/helpers/projects_helper.rb
      app/components/button.rb app/frontend/button.js config/locales/en.yml
      app/controllers/projects_controller.rb app/controllers/projects/settings_controller.rb
      public/icon.svg app/models/project.rb app/services/example.rb spec/models/project_spec.rb
      app/controllers/api/projects_controller.rb app/controllers/concerns/example_controller.rb
      app/views/devise/mailer/reset.html.erb app/views/layouts/mailer.html.erb
      app/views/pwa/service-worker.js config/locales/devise.en.yml
      app/controllers/health_controller.rb app/controllers/operator_console_access_controller.rb
      app/controllers/projects/staged_closeout_adoptions_controller.rb
    ]
  end

  # @spec SCREENSHOT-CI-001
  it "filters capture events consistently with Rails UI paths and leaves cleanup unfiltered" do
    paths = capture.fetch("on").fetch("pull_request").fetch("paths")
    example_paths.each do |path|
      selected = false
      paths.each do |pattern|
        excluded = pattern.start_with?("!")
        glob = excluded ? pattern.delete_prefix("!") : pattern
        glob = "#{glob}/*" if glob.end_with?("/**")
        selected = !excluded if File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
      expected = Screenshots::DetectUiChanges.call(changed_files: [ path ], framework: :rails).fetch(:ui_changes?)
      expect(selected).to eq(expected), path
    end
    expect(capture.fetch("on").fetch("pull_request_target")).to eq("types" => [ "closed" ])
  end

  # @spec SCREENSHOT-CI-004
  it "resolves outcomes without services or storage secrets and gates the publishing job" do
    resolver = publish.fetch("jobs").fetch("resolve")
    expect(resolver).not_to have_key("services")
    expect(resolver.fetch("permissions").values).to all(eq("read"))
    expect(resolver.to_s).not_to include("secrets.", "bundler-cache", "db:schema:load")
    publisher = publish.fetch("jobs").fetch("publish")
    expect(publisher.fetch("needs")).to eq("resolve")
    expect(publisher.fetch("if")).to include("needs.resolve.outputs.comment_status != 'skip'")
  end

  def run_resolver(files:, comments: [], action: "synchronize", files_status: 200, exits: true)
    stub_request(:get, "#{repo_url}/pulls/42/files?per_page=100&page=1")
      .to_return(status: files_status, body: files.to_json)
    stub_request(:get, "#{repo_url}/issues/42/comments?per_page=100&page=1")
      .to_return(body: comments.to_json)
    script = publish.fetch("jobs").fetch("resolve").fetch("steps")
      .find { |step| step["id"] == "resolve" }.fetch("run")
      .delete_prefix("ruby <<'RUBY'\n").delete_suffix("RUBY\n")
    Tempfile.create("screenshot-resolver") do |output|
      values = {
        "GITHUB_REPOSITORY" => "viamin/paid", "PR_NUMBER" => "42", "HEAD_SHA" => "abc",
        "HEAD_REF" => "example", "PR_UPDATED_AT" => "2026-11-27T00:00:00Z",
        "PR_ACTION" => action, "GITHUB_TOKEN" => "test", "GITHUB_OUTPUT" => output.path
      }
      allow(ENV).to receive(:fetch).and_call_original
      values.each { |key, value| allow(ENV).to receive(:fetch).with(key).and_return(value) }
      if exits
        expect { Object.new.instance_eval(script, "resolver", 1) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
      else
        Object.new.instance_eval(script, "resolver", 1)
      end
      File.read(output.path)
    end
  end

  # @spec SCREENSHOT-CI-002
  it "skips non-UI PRs without polling capture runs" do
    expect(run_resolver(files: [ { "filename" => "app/models/project.rb" } ])).to match(/comment_status<<.*\nskip\n/)
  end

  # @spec SCREENSHOT-CI-003
  it "marks an existing screenshot comment stale without polling capture runs" do
    comments = [ { "body" => "<!-- pr-screenshots-comment -->" } ]
    expect(run_resolver(files: [], comments: comments)).to match(/comment_status<<.*\nno_ui_changes\n/)
    expect(run_resolver(files: [], comments: comments, action: "opened")).to match(/comment_status<<.*\nskip\n/)
  end

  # @spec SCREENSHOT-CI-005
  it "checks later file and comment pages" do
    stub_request(:get, "#{repo_url}/pulls/42/files?per_page=100&page=2")
      .to_return(body: [].to_json)
    stub_request(:get, "#{repo_url}/issues/42/comments?per_page=100&page=2")
      .to_return(body: [ { "body" => "<!-- pr-screenshots-comment -->" } ].to_json)
    result = run_resolver(files: Array.new(100) { { "filename" => "README.md" } }, comments: Array.new(100) { { "body" => "other" } })
    expect(result).to match(/comment_status<<.*\nno_ui_changes\n/)
    expect(a_request(:get, "#{repo_url}/pulls/42/files?per_page=100&page=2")).to have_been_made.once
  end

  # @spec SCREENSHOT-CI-005
  it "continues to resolve and publish captures when a later file page includes UI changes" do
    stub_request(:get, "#{repo_url}/pulls/42/files?per_page=100&page=2")
      .to_return(body: [ { "filename" => "app/views/projects/show.html.erb" } ].to_json)
    run = {
      "id" => 123, "head_sha" => "abc", "head_branch" => "example",
      "status" => "completed", "created_at" => "2026-11-27T00:00:00Z",
      "jobs_url" => "#{repo_url}/actions/runs/123/jobs"
    }
    stub_request(:get, %r{#{repo_url}/actions/workflows/pr-screenshots.yml/runs\?})
      .to_return(body: { "workflow_runs" => [ run ] }.to_json)
    stub_request(:get, "#{repo_url}/actions/runs/123/jobs")
      .to_return(body: { "jobs" => [ { "name" => "capture", "conclusion" => "success" } ] }.to_json)
    stub_request(:get, "#{repo_url}/actions/runs/123/artifacts?per_page=100")
      .to_return(body: { "artifacts" => [ { "name" => "pr-screenshots", "expired" => false } ] }.to_json)
    result = run_resolver(files: Array.new(100) { { "filename" => "README.md" } }, exits: false)
    expect(result).to match(/comment_status<<.*\nsuccess\n/)
    expect(result).to match(/artifact_present<<.*\ntrue\n/)
    expect(a_request(:get, "#{repo_url}/issues/42/comments?per_page=100&page=1")).not_to have_been_made
  end

  # @spec SCREENSHOT-CI-005
  it "reports API errors as capture failures" do
    expect(run_resolver(files: [], files_status: 403)).to match(/comment_status<<.*\ncapture_failed\n/)
  end
end
