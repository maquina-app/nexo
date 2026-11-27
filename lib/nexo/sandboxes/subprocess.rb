# frozen_string_literal: true

require "timeout"

module Nexo
  module Sandboxes
    # Runs a host process with a timeout that actually stops it.
    #
    # `Timeout.timeout { Open3.capture3(...) }` does not: Open3 waits for the child
    # in its own `ensure`, so the timeout surfaces only once the command has
    # finished by itself. This starts the command in its own process group, reads
    # both streams on threads, and kills the whole group when the time is up —
    # the command and everything it started.
    module Subprocess
      module_function

      # Runs `argv` (a command String for the shell, or a program and its
      # arguments) with exactly the environment `env` — nothing is inherited — and
      # returns `[stdout, stderr, exit_status]`. Raises `Timeout::Error` after
      # `timeout` seconds, with the process group already killed. `chdir:` sets
      # the working directory; `stdin_data:` is written to the command's standard
      # input, which is otherwise empty.
      def capture(env, *argv, timeout:, chdir: nil, stdin_data: nil)
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe
        in_read, in_write = IO.pipe if stdin_data
        options = {in: in_read || File::NULL, out: out_write, err: err_write, pgroup: true, unsetenv_others: true}
        options[:chdir] = chdir if chdir
        pid = Process.spawn(env, *argv, **options)
        out_write.close
        err_write.close
        in_read&.close
        writer = feeder(in_write, stdin_data) if stdin_data
        readers = [out_read, err_read].map { |io| reader(io) }
        _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
        [readers[0].value.to_s, readers[1].value.to_s, status.exitstatus]
      rescue Timeout::Error
        kill_group(pid)
        raise Timeout::Error, "command timed out after #{timeout}s and was killed"
      ensure
        writer&.kill
        [out_read, out_write, err_read, err_write, in_read, in_write].each { |io| io&.close unless io&.closed? }
      end

      # Feeds `data` to the command on its own thread, so a command that reads
      # slowly — or never — cannot block the caller past the timeout.
      def feeder(io, data)
        Thread.new do
          io.write(data)
          io.close
        rescue IOError, Errno::EPIPE
          nil
        end.tap { |thread| thread.report_on_exception = false }
      end

      # Drains one pipe on its own thread so a chatty command cannot fill the
      # pipe buffer and block. A read cut short by the timeout teardown is nil.
      def reader(io)
        Thread.new do
          io.read
        rescue IOError
          nil
        end.tap { |thread| thread.report_on_exception = false }
      end

      # Kills the command's whole process group and reaps it. Best-effort: the
      # group may already be gone.
      def kill_group(pid)
        return unless pid

        Process.kill("KILL", -pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
        nil
      end
    end
  end
end
