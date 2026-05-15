# frozen_string_literal: true

require "rails_helper"

class RunnerFormBridgeFile < Pathname
end

RSpec.describe RunnerFormBridgeFile, :no_db do
  let(:stimulus_manifest) { Rails.root.join("app/javascript/controllers/index.js").read }
  let(:runner_controller) { Rails.root.join("app/javascript/controllers/runner_form_controller.js").read }
  let(:provider_controller) { Rails.root.join("app/javascript/controllers/provider_form_controller.js").read }
  let(:runner_form) { Rails.root.join("app/views/runners/_form.html.erb").read }
  let(:provider_form) { Rails.root.join("app/views/providers/_form.html.erb").read }
  let(:runners_controller) { Rails.root.join("app/controllers/runners_controller.rb").read }

  it "keeps the legacy provider form Stimulus controller registered during the phase-1 bridge" do
    expect(stimulus_manifest).to include('application.register("provider-form", ProviderFormController)')
  end

  it "supports aider API-key configuration in both runner and provider form controllers" do
    expect(runner_controller).to include('const DYNAMIC_API_RUNNER_KEYS = new Set(["opencode", "kilocode", "aider"])')
    expect(provider_controller).to include('const DYNAMIC_API_PROVIDER_KEYS = new Set(["opencode", "kilocode", "aider"])')
    expect(runner_controller).to include('"aiderSettings"')
    expect(provider_controller).to include('"aiderSettings"')
  end

  it "renders aider model settings in both bridge forms" do
    expect(runner_form).to include('name="runner[config][aider][api_provider]"')
    expect(runner_form).to include('name="runner[config][aider][model]"')
    expect(provider_form).to include('name="provider[config][aider][api_provider]"')
    expect(provider_form).to include('name="provider[config][aider][model]"')
  end

  it "permits aider config through the runners controller bridge" do
    expect(runners_controller).to include("aider: [ :api_provider, :model ]")
  end
end
