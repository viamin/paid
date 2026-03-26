# frozen_string_literal: true

RSpec.shared_context "without qdrant vector search" do
  before do
    allow(Paid).to receive(:qdrant_url).and_return(nil)
  end
end
