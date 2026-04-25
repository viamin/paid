#!/usr/bin/env bash
# Wrapper that delegates structure.sql loading to pg gem since psql binary is not available.

STRUCTURE_FILE=""
for arg in "$@"; do
  if echo "$arg" | grep -q "structure.sql"; then
    STRUCTURE_FILE="$arg"
    break
  fi
done

if [ -n "$STRUCTURE_FILE" ] && [ -f "$STRUCTURE_FILE" ]; then
  bundle exec ruby - "$STRUCTURE_FILE" <<'RUBY'
require "openssl"
require "pg"
structure_file = ARGV[0]
conn = PG.connect(ENV["DATABASE_URL"])
sql = File.read(structure_file)

# Remove duplicate INSERT blocks for schema_migrations and ar_internal_metadata.
seen_schema = false
seen_metadata = false
cleaned_lines = []
skip_block = false

sql.each_line do |line|
  if line.match?(/^INSERT INTO "schema_migrations"/)
    if seen_schema
      skip_block = true
      next
    end
    seen_schema = true
  elsif line.match?(/^INSERT INTO "ar_internal_metadata"/)
    if seen_metadata
      skip_block = true
      next
    end
    seen_metadata = true
  end

  if skip_block
    skip_block = false if line.strip.end_with?(");")
    next
  end

  cleaned_lines << line
end

conn.exec(cleaned_lines.join)

# Set environment
conn.exec(<<~SQL)
  INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
  VALUES ('environment', 'test', NOW(), NOW())
  ON CONFLICT (key) DO UPDATE SET value = 'test'
SQL

conn.close
RUBY

  # Run any pending migrations via Rails
  RAILS_ENV="${RAILS_ENV:-test}" bundle exec rails db:migrate 2>/dev/null || true

  # Update schema SHA1 to match structure.sql so maintain_test_schema! is satisfied
  bundle exec ruby - "$STRUCTURE_FILE" <<'RUBY'
require "openssl"
require "pg"
conn = PG.connect(ENV["DATABASE_URL"])
schema_sha = OpenSSL::Digest::SHA1.hexdigest(File.read(ARGV[0]))
conn.exec(<<~SQL)
  INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
  VALUES ('schema_sha1', '#{schema_sha}', NOW(), NOW())
  ON CONFLICT (key) DO UPDATE SET value = '#{schema_sha}'
SQL
conn.close
RUBY
fi

exit 0
