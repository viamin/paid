require 'pg'

file = nil
database = nil
i = 0
args = ARGV.dup
while i < args.length
  case args[i]
  when '--file', '-f'
    file = args[i + 1]; i += 2
  when '--set'
    i += 2
  when '--output', '-o'
    i += 2
  when /^-/
    i += 1
  else
    database = args[i]; i += 1
  end
end

url = ENV['DATABASE_URL']
conn = PG.connect(url)
conn.exec(File.read(file)) if file
