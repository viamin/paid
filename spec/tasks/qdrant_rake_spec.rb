# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "qdrant:check" do
  let(:task) { Rake::Task["qdrant:check"] }
  let(:qdrant_client) { instance_double(QdrantClient) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("qdrant:check")
    task.reenable

    allow(Paid).to receive_messages(qdrant_client: qdrant_client, qdrant_url: "http://localhost:6333")
  end

  context "when Qdrant is reachable" do
    before { allow(qdrant_client).to receive(:healthy?).and_return(true) }

    it "prints a success message" do
      expect { task.invoke }.to output(/Qdrant is reachable/).to_stdout
    end
  end

  context "when Qdrant is unreachable" do
    before { allow(qdrant_client).to receive(:healthy?).and_return(false) }

    it "prints a warning message" do
      expect { task.invoke }.to output(/WARNING.*not responding/).to_stdout
    end

    it "suggests starting Qdrant with docker compose" do
      expect { task.invoke }.to output(/docker compose up qdrant/).to_stdout
    end
  end
end
# rubocop:enable RSpec/DescribeClass
