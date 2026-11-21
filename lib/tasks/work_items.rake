# frozen_string_literal: true

namespace :work_items do
  desc "Offline GitHub issue migration. Required: ACCOUNT_ID=<id>. Optional: SINCE=<ISO-8601 maintenance-window start>."
  task migrate_github_issues: :environment do # @spec UNIFIED-WORK-ITEMS-007
    account = Account.find(Integer(ENV.fetch("ACCOUNT_ID")))
    since = ENV["SINCE"] && Time.iso8601(ENV.fetch("SINCE"))
    result = WorkItems::MigrateGithubIssues.call(account:, since:)

    puts "GitHub work-item migration for account #{account.id}:"
    puts "  migrated: #{result.migrated_count}"
    puts "  reconciled: #{result.reconciled_count}" if since
  end
end
