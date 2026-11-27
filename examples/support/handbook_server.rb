# frozen_string_literal: true

# A minimal MCP server over stdio that offers a folder of Markdown files as
# RESOURCES (things to read) and no tools. It exists so examples/company_brain.rb
# runs with nothing installed; it is not a general MCP server.
#
#   ruby examples/support/handbook_server.rb <directory>
#
# One JSON-RPC message per line on stdin, one reply per line on stdout.
require "json"

root = File.expand_path(ARGV.fetch(0))
pages = Dir[File.join(root, "*.md")].sort.to_h { |path| ["handbook://#{File.basename(path, ".md")}", path] }
$stdout.sync = true

handlers = {
  "initialize" => lambda { |params|
    {protocolVersion: params["protocolVersion"], capabilities: {resources: {}, tools: {}},
     serverInfo: {name: "handbook", version: "1"}}
  },
  "ping" => ->(_) { {} },
  "tools/list" => ->(_) { {tools: []} },
  "resources/list" => lambda { |_|
    {resources: pages.map do |uri, path|
      {uri: uri, name: File.basename(path, ".md"), mimeType: "text/markdown", description: File.foreach(path).first.to_s.delete("#").strip}
    end}
  },
  "resources/read" => lambda { |params|
    path = pages.fetch(params["uri"]) { raise KeyError, "no resource #{params["uri"]}" }
    {contents: [{uri: params["uri"], mimeType: "text/markdown", text: File.read(path)}]}
  }
}

while (line = $stdin.gets)
  message = JSON.parse(line)
  next unless message.key?("id") # a notification: nothing to answer

  reply = {jsonrpc: "2.0", id: message["id"]}
  begin
    handler = handlers[message["method"]]
    handler ? reply[:result] = handler.call(message["params"] || {}) : reply[:error] = {code: -32_601, message: "unknown method #{message["method"]}"}
  rescue KeyError => e
    reply[:error] = {code: -32_602, message: e.message}
  end
  puts JSON.generate(reply)
end
