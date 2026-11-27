# frozen_string_literal: true

# The local shell inside an OS sandbox: a command can write only in the working
# directory, cannot read your home directory, and has no network. No model.
#
#   ruby -Ilib examples/confined_shell.rb
#
# Needs the `mxc` gem and an OS it supports (Seatbelt on macOS, Bubblewrap on
# Linux). The file tools of a `:local` sandbox were always fenced to the working
# directory; a shell command is a process on your machine, and this is what
# fences it too.
require "nexo"
require "tmpdir"

def run(sandbox, label, command)
  out = sandbox.shell(command)
  result = (out[:status].zero? ? "ok" : "refused").ljust(8)
  puts "  #{result}#{label.ljust(30)} #{(out[:stdout] + out[:stderr]).strip.lines.first.to_s.strip[0, 60]}"
end

if __FILE__ == $PROGRAM_NAME
  Dir.mktmpdir("nexo-confined") do |dir|
    workspace = File.realpath(dir)
    secret = File.join(Dir.home, ".nexo-example-secret")
    File.write(secret, "TOP SECRET")

    begin
      # `readable: :ruby` grants the running Ruby's install and gem paths, which a
      # Ruby under your home directory needs in order to start.
      confined = Nexo::Sandboxes::Local.new(cwd: workspace, isolation: :confined, readable: :ruby)
      confined.shell("true") # a machine that cannot confine raises here
    rescue Nexo::ConfigurationError, Nexo::MissingDependencyError => e
      File.delete(secret)
      abort "this machine cannot confine a shell: #{e.message}"
    end

    open_shell = Nexo::Sandboxes::Local.new(cwd: workspace)
    commands = {
      "write inside the workspace" => "echo made > made.txt && cat made.txt",
      "run a Ruby script" => %(#{RbConfig.ruby} -e 'require "json"; puts JSON.generate(ok: true)'),
      "read a file in your home" => "cat #{secret}",
      "write outside the workspace" => "touch #{File.join(Dir.home, ".nexo-example-escape")}",
      "reach the network" => "curl -s -m 3 -o /dev/null https://example.com && echo reached"
    }

    puts "isolation: :confined"
    commands.each { |label, command| run(confined, label, command) }
    puts "what it does not contain: #{confined.hardening_gaps.inspect}"

    puts "\nno isolation (the default :local shell)"
    commands.each { |label, command| run(open_shell, label, command) }
    puts "what it does not contain: #{open_shell.hardening_gaps.inspect}"
  ensure
    [secret, File.join(Dir.home, ".nexo-example-escape")].each { |path| File.delete(path) if File.exist?(path) }
  end
end
