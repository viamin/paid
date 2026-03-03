# frozen_string_literal: true

namespace :qdrant do
  desc "Check Qdrant connectivity and print status"
  task check: :environment do
    url = Paid.qdrant_url
    if Paid.qdrant_client.healthy?
      puts "  Qdrant is reachable at #{url}"
    else
      abort "  WARNING: Qdrant is not responding at #{url}\n  Run 'docker compose up qdrant -d' to start Qdrant"
    end
  end
end
