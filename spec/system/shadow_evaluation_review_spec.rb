# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Reviewing code changes", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:owner) { create(:user, :owner) }
  let(:project) { create(:project, account: owner.account) }
  let(:dir) { Dir.mktmpdir }
  let(:client) { instance_double(GithubClient) }
  let(:evaluation) do
    item = { "id" => "review-1", "repository" => project.full_name, "base_sha" => "a" * 40,
             "head_sha" => "b" * 40, "approved_design_revision" => "c" * 40,
             "design_document_paths" => [ "docs/requirements.md" ] }
    path = File.join(dir, "sample.yml")
    File.write(path, { "cases" => [ item ] }.to_yaml)
    create(:intent_conformance_shadow_evaluation, project:, solo_maintainer: owner,
      created_by: owner, manifest_path: path, manifest_digest: Digest::SHA256.file(path).hexdigest)
  end

  let(:contrast_script) do
    <<~JS
    (() => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      const context = canvas.getContext('2d');
      const luminance = color => {
        context.fillStyle = color;
        context.fillRect(0, 0, 1, 1);
        const channels = [...context.getImageData(0, 0, 1, 1).data].slice(0, 3).map(value => {
          const s = value / 255;
          return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
        });
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
      };
      const background = luminance(getComputedStyle(this).backgroundColor);
      return [...this.querySelectorAll('span.block')].map(span => {
        const foreground = luminance(getComputedStyle(span).color);
        return (Math.max(background, foreground) + 0.05) / (Math.min(background, foreground) + 0.05);
      });
    })()
    JS
  end

  before do
    Warden.test_mode!
    login_as(owner, scope: :user)
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      compare: { commits: [ { sha: "b" * 40, commit: { message: "Use explicit queue labels (#42)" } } ], files: [
        { filename: "app/example.rb", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old_behavior\n+new_behavior" }
      ] },
      pull_request: { merge_commit_sha: "b" * 40, title: "Use explicit queue labels",
        body: "Only configured labels exclude work. [Details](https://example.org)" }
    )
    allow(client).to receive(:file_content).with(project.full_name, path: "docs/requirements.md", ref: "c" * 40)
      .and_return("# Queue requirements\n\nOnly configured labels exclude work.")
  end

  after do
    Warden.test_reset!
    FileUtils.remove_entry(dir)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-010 @spec INTENT-CONFORMANCE-ROLLOUT-012
  it "leads with the summary and keeps file diffs closed on desktop and mobile" do
    [ 1440, 390 ].each do |width|
      page.current_window.resize_to(width, 1000)
      visit project_shadow_evaluation_path(project, evaluation)

      expect(page).to have_css("[data-change-summary]", text: "Use explicit queue labels")
      expect(page).not_to have_css("[data-file-diff] pre", text: "new_behavior")
      find("[data-file-diff] summary").click
      expect(page).to have_css("[data-file-diff] pre", text: "new_behavior")
      find("[data-file-diff] summary").click
      expect(page).to have_text("Not enough information")
      expect(find("[data-change-summary]").evaluate_script("getComputedStyle(this).borderRadius")).not_to eq("0px")
      expect(page).to have_button("Finish my review", disabled: true)
      expect(find_link("Open full diff in a new tab")[:target]).to eq("_blank")
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= width
      page.save_screenshot("/tmp/paid-review-overview-#{width}.png", full: true)
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-012
  it "keeps selected decision text readable in both themes" do
    visit project_shadow_evaluation_path(project, evaluation)
    expect(page).to have_css("[data-change-summary]")

    [ false, true ].each do |dark|
      page.execute_script("document.documentElement.classList.toggle('dark', arguments[0])", dark)
      [ "Matches the approved requirements", "Changes the approved requirements", "Not enough information" ].each do |choice|
        choose choice
        label = find("input[type=radio]:checked").find(:xpath, "..")
        ratios = label.evaluate_script(contrast_script)
        expect(ratios.size).to eq(2)
        expect(ratios).to all(be >= 4.5)
      end
    end
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-012
  it "saves uncertainty without a citation and keeps finalizing separate" do
    visit project_shadow_evaluation_path(project, evaluation)
    expect(page).to have_css("[data-change-summary]", text: "Use explicit queue labels")
    choose "Not enough information"
    expect(find_field("What led you to this decision? (optional)")[:required]).to be_falsey
    click_button "Save decision and continue"

    expect(page).to have_text("1 of 1 reviewed")
    expect(page).to have_button("Finish my review", disabled: false)
    CapybaraTenantContext.with_fixture_session do
      expect(evaluation.labels.sole.outcome).to eq("uncertain")
      expect(evaluation.reload).to be_labeling
      expect(evaluation.runs).to be_empty
    end
  end
end
