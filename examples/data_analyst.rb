# frozen_string_literal: true

# A data analyst: it answers questions by running SQL, reads freely, and has to
# ask before it changes anything. (After Eve's "Data agent" template.)
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/data_analyst.rb
#
# Needs the `sqlite3` command. Two tools, two capabilities:
#
#   * `QuerySql` is `:read`. It opens the database read-only, so the guarantee is
#     the database's, not a guess about what the SQL does.
#   * `ExecuteSql` is `:write`. Under `:ask` every call is put to `on_ask` — here a
#     hook that prints the statement and refuses unless NEXO_APPROVE=1.
#
# `:ask` is the synchronous sibling of `:approve`: right when a person is at the
# keyboard while the agent runs.
require "nexo"
require "tmpdir"
require_relative "support/model"

DATABASE = File.join(Dir.mktmpdir("nexo-analyst"), "shop.db")

def sqlite(*arguments, sql)
  out, err, status = Nexo::Sandboxes::Subprocess.capture({"PATH" => ENV["PATH"]}, "sqlite3", *arguments, DATABASE, sql, timeout: 10)
  (status == 0) ? out : {error: err.strip}
rescue Timeout::Error => e
  {error: e.message}
end

class DescribeTables < RubyLLM::Tool
  description "Lists the tables in the database with their columns."

  def execute = sqlite("-readonly", "SELECT name, sql FROM sqlite_master WHERE type = 'table'")
end

class QuerySql < RubyLLM::Tool
  description "Runs one read-only SQL query and returns the rows, with a header line."
  parameter :sql, type: :string, description: "A SELECT statement"

  def execute(sql:) = sqlite("-readonly", "-header", sql)
end

class ExecuteSql < RubyLLM::Tool
  description "Runs one SQL statement that changes data (INSERT, UPDATE, DELETE)."
  parameter :sql, type: :string, description: "The statement"

  def execute(sql:)
    result = sqlite(sql)
    result.is_a?(Hash) ? result : "Done."
  end
end

class Analyst < Nexo::Agent
  Examples.model(self)
  file_tools :none
  permissions Nexo::Permissions.new(
    mode: :ask,
    on_ask: lambda { |capability, detail|
      approved = ENV["NEXO_APPROVE"] == "1"
      puts "  [asked] #{capability}: #{detail}  ->  #{approved ? "approved" : "refused (set NEXO_APPROVE=1 to allow)"}"
      approved
    }
  )
  tools DescribeTables, QuerySql, capability: :read
  tools ExecuteSql, capability: :write

  instructions "You are a data analyst. Look at the tables before you query. Answer with the numbers you found. " \
               "If a change is refused, say so and do not try another way."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]
  abort "this example needs the sqlite3 command" unless system("command -v sqlite3 > /dev/null 2>&1")

  sqlite(<<~SQL)
    CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, test INTEGER DEFAULT 0);
    CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL);
    INSERT INTO customers VALUES (1, 'Ada', 0), (2, 'Grace', 0), (3, 'QA Bot', 1);
    INSERT INTO orders VALUES (1, 1, 120.0), (2, 1, 80.5), (3, 2, 310.0), (4, 3, 9999.0);
  SQL

  agent = Analyst.new
  puts "== A question: reads only =="
  puts agent.prompt("Which real (non-test) customer has spent the most, and how much?").content

  puts "\n== A change: it has to ask =="
  puts agent.prompt("Delete the orders that belong to test customers.").content

  puts "\norders left: #{sqlite("-readonly", "SELECT COUNT(*) FROM orders").to_s.strip}"
end
