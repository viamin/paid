# frozen_string_literal: true

namespace :prompts do
  desc "Synchronize application-owned global prompt defaults"
  task sync_defaults: :environment do
    # @spec PROMPT-DEFAULT-SYNC-005
    load Rails.root.join("db/seeds/prompts.rb")
  end
end
