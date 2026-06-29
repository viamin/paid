# frozen_string_literal: true

class UpdateTriggerLogidzeOnRunnerCredentialsToVersion2 < ActiveRecord::Migration[8.1]
  def change
    update_trigger :logidze_on_runner_credentials, on: :runner_credentials, version: 2, revert_to_version: 1
  end
end
