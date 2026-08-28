# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "containers:rebuild_combo_images" do
  let(:task) { Rake::Task["containers:rebuild_combo_images"] }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("containers:rebuild_combo_images")
    task.reenable
    allow(Containers).to receive(:all_backends).and_return([ backend ])
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend).and_return([])
    allow(Containers::ComboImageBuilder).to receive(:force_rebuild)
  end

  it "rebuilds combo images already present on a backend" do
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend)
      .and_return([ { image: "paid-agent:go" } ])

    expect { task.invoke }.to output(/Rebuilt paid-agent:go on local/).to_stdout
    expect(Containers::ComboImageBuilder).to have_received(:force_rebuild).with("paid-agent:go", backend: backend)
  end

  it "rebuilds combo images resolved from a project's repo profile" do
    create(:project, repo_profile: { "test_languages" => %w[go] })

    task.invoke

    expect(Containers::ComboImageBuilder).to have_received(:force_rebuild).with("paid-agent:go", backend: backend)
  end

  it "resolves projects across every tenant, not only the invoking process's own account" do
    other_account = create(:account)
    create(:project, account: other_account, repo_profile: { "test_languages" => %w[rust] })

    task.invoke

    expect(Containers::ComboImageBuilder).to have_received(:force_rebuild).with("paid-agent:rust", backend: backend)
  end

  it "does not rebuild base-only projects" do
    create(:project, repo_profile: { "test_languages" => %w[ruby] })

    task.invoke

    expect(Containers::ComboImageBuilder).not_to have_received(:force_rebuild)
  end

  it "does not rebuild a combo tag resolved from a project with an unsupported runtime" do
    create(:project, repo_profile: { "test_languages" => %w[kotlin go] })

    task.invoke

    expect(Containers::ComboImageBuilder).not_to have_received(:force_rebuild)
  end

  it "aborts after logging failures without stopping the rest of the sweep" do
    allow(Containers::ComboImageBuilder).to receive(:combo_images).with(backend: backend)
      .and_return([ { image: "paid-agent:go" }, { image: "paid-agent:rust" } ])
    allow(Containers::ComboImageBuilder).to receive(:force_rebuild).with("paid-agent:go", backend: backend)
      .and_raise(Containers::ComboImageBuilder::Error, "boom")

    expect { task.invoke }.to raise_error(SystemExit)
    expect(Containers::ComboImageBuilder).to have_received(:force_rebuild).with("paid-agent:rust", backend: backend)
  end
end
# rubocop:enable RSpec/DescribeClass
