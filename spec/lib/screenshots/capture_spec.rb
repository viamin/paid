# frozen_string_literal: true

require "rails_helper"
require "screenshots/capture"

RSpec.describe Screenshots::Capture do
  let(:session) { instance_double(Capybara::Session, current_path: "/projects/1") }
  let(:driver) { instance_double(Capybara::Cuprite::Driver, quit: true) }
  let(:seed_data) { { user: instance_double(User), project: instance_double(Project, id: 1) } }
  let(:output_dir) { Dir.mktmpdir }
  let(:target) do
    Screenshots::CaptureTargets::Target.new(
      slug: "project_show",
      path_builder: "/projects/1",
      requires_auth: true
    )
  end

  before do
    allow(Capybara::Session).to receive(:new)
      .with(:paid_screenshots, Capybara.app)
      .and_return(session)
    allow(session).to receive_messages(driver: driver, has_no_css?: true)
    allow(session).to receive(:visit)
    allow(session).to receive(:save_screenshot)
    allow(Screenshots::CaptureTargets).to receive(:call).and_return([ target ])
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  around do |example|
    original_chrome_url = ENV["CHROME_URL"]
    original_app_host = ENV["CAPYBARA_APP_HOST"]
    example.run
  ensure
    ENV["CHROME_URL"] = original_chrome_url
    ENV["CAPYBARA_APP_HOST"] = original_app_host
  end

  it "passes changed files into target resolution" do
    capture = described_class.new(output_dir: output_dir, changed_files: [ "app/views/projects/show.html.erb" ])
    allow(capture).to receive(:register_driver)
    allow(capture).to receive(:setup_capybara)
    allow(capture).to receive(:ensure_seed_data!).and_return(seed_data)
    allow(capture).to receive(:sign_in)

    capture.call

    expect(Screenshots::CaptureTargets).to have_received(:call).with(
      changed_files: [ "app/views/projects/show.html.erb" ]
    )
  end

  it "raises when any mapped target fails to capture" do
    capture = described_class.new(output_dir: output_dir, changed_files: [ "app/views/projects/show.html.erb" ])
    allow(capture).to receive(:register_driver)
    allow(capture).to receive(:setup_capybara)
    allow(capture).to receive(:ensure_seed_data!).and_return(seed_data)
    allow(capture).to receive(:sign_in)
    allow(session).to receive(:visit).and_raise(StandardError, "boom")

    expect { capture.call }.to raise_error(RuntimeError, /project_show .* boom/)
    expect(driver).to have_received(:quit)
  end

  it "requires CAPYBARA_APP_HOST when CHROME_URL is configured" do
    capture = described_class.new(output_dir: output_dir, changed_files: [])
    ENV["CHROME_URL"] = "ws://localhost:9222"
    ENV.delete("CAPYBARA_APP_HOST")

    expect { capture.send(:setup_capybara) }.to raise_error(
      RuntimeError,
      /CAPYBARA_APP_HOST must be set/
    )
  end

  describe "seed data reuse across consecutive calls", :db do
    def run_capture(dir)
      capture = described_class.new(output_dir: dir, changed_files: [])
      allow(capture).to receive(:register_driver)
      allow(capture).to receive(:setup_capybara)
      allow(capture).to receive(:sign_in)
      capture.call
    end

    def attach_stale_associations(agent_run)
      agent_run.quality_metrics.create!(
        metric_type: "automated", scores: { coverage: 0.85 },
        composite_score: 0.85, feedback_source: "system"
      )
      llm_model = LlmModel.find_or_create_by!(model_id: "gpt-4", provider: "openai") do |m|
        m.display_name = "GPT-4"
        m.family = "gpt-4"
        m.category = "general"
        m.tier = "high"
        m.context_window = 128_000
        m.max_output_tokens = 4096
        m.input_cost_per_million = 30.0
        m.output_cost_per_million = 60.0
        m.capability_score = 9
        m.active = true
      end
      agent_run.create_model_selection!(llm_model: llm_model, selector_type: "meta_agent", reasoning: "test")
    end

    def seed_and_dirty_agent_run(dir)
      run_capture(dir)
      AgentRun.find_by!(custom_prompt: "Capture screenshot route coverage").tap do |run|
        run.update!(
          status: "completed",
          source_pull_request_number: 42,
          review_url: "https://github.com/o/r/pull/42/reviews/1",
          review_posted_at: 1.hour.ago,
          created_issue_url: "https://github.com/o/r/issues/99",
          created_issue_number: 99,
          pull_request_url: "https://github.com/o/r/pull/50",
          pull_request_number: 50,
          started_at: 2.hours.ago,
          completed_at: 1.hour.ago
        )
      end
    end

    let(:reused_run) do
      original = seed_and_dirty_agent_run(output_dir)
      run_capture(output_dir)
      original.reload
    end

    it "reuses the same record and resets status" do
      expect(reused_run.status).to eq("queued")
      expect(AgentRun.where(custom_prompt: "Capture screenshot route coverage").count).to eq(1)
    end

    it "clears issue and PR context fields" do
      expect(reused_run).to have_attributes(
        source_pull_request_number: nil,
        pull_request_url: nil,
        pull_request_number: nil,
        created_issue_url: nil,
        created_issue_number: nil
      )
    end

    it "clears review and timing fields" do
      expect(reused_run).to have_attributes(
        review_url: nil,
        review_posted_at: nil,
        started_at: nil,
        completed_at: nil
      )
    end

    it "clears stale quality_metrics and model_selection associations" do
      original = seed_and_dirty_agent_run(output_dir)
      attach_stale_associations(original)

      run_capture(output_dir)
      original.reload

      expect(original.quality_metrics).to be_empty
      expect(original.model_selection).to be_nil
    end
  end

  describe "#register_driver" do
    it "passes base_url to Cuprite when app_host is set" do
      capture = described_class.new(output_dir: output_dir, changed_files: [])
      app_host = "http://127.0.0.1:3001"
      cuprite_driver = instance_double(Capybara::Cuprite::Driver)

      allow(Capybara).to receive(:app_host).and_return(app_host)
      allow(Capybara::Cuprite::Driver).to receive(:new).and_return(cuprite_driver)

      capture.send(:register_driver)

      # Trigger the registered driver block by calling it with a mock app
      mock_app = instance_double(Rack::Builder)
      Capybara.drivers[:paid_screenshots].call(mock_app)

      expect(Capybara::Cuprite::Driver).to have_received(:new) do |app, **options|
        expect(app).to eq(mock_app)
        expect(options[:base_url]).to eq(app_host)
      end
    end

    it "omits base_url from Cuprite when app_host is nil" do
      capture = described_class.new(output_dir: output_dir, changed_files: [])
      cuprite_driver = instance_double(Capybara::Cuprite::Driver)

      allow(Capybara).to receive(:app_host).and_return(nil)
      allow(Capybara::Cuprite::Driver).to receive(:new).and_return(cuprite_driver)

      capture.send(:register_driver)

      mock_app = instance_double(Rack::Builder)
      Capybara.drivers[:paid_screenshots].call(mock_app)

      expect(Capybara::Cuprite::Driver).to have_received(:new) do |_app, **options|
        expect(options).not_to have_key(:base_url)
      end
    end
  end
end
