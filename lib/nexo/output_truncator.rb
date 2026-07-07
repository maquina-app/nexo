# frozen_string_literal: true

module Nexo
  # Bounds unbounded command output before it reaches the model, so a single
  # +npm install+ or +git log+ can't blow a small context window. Pure and
  # dependency-free — line/char based, no tokenizer (a token budget would be
  # expensive to reimplement and is out of scope for v1).
  #
  # The transform, in order: strip ANSI SGR escapes, keep the *last*
  # +max_lines+ lines (the tail is where errors and exit summaries live), append
  # a +…[truncated N lines]+ marker when lines were dropped, then hard-cap the
  # result at +max_chars+ characters. Configurable via kwargs only — there is no
  # +Nexo.config+ global and no per-agent macro in v1.
  module OutputTruncator
    # Matches ANSI SGR color/style escapes (e.g. +\e[31m+, +\e[1;32m+, +\e[0m+),
    # the escapes real command output emits. VERIFIED against real output in
    # Group 0.
    ANSI = /\e\[[0-9;]*m/

    module_function

    # Strips ANSI escapes from +text+, keeps the last +max_lines+ lines (with a
    # +…[truncated N lines]+ marker when it trims), then caps the result at
    # +max_chars+. Pure line/char truncation — no tokenizer.
    def call(text, max_lines: 200, max_chars: 16_000)
      return text if text.nil? || text.empty?

      stripped = text.gsub(ANSI, "")
      lines = stripped.split("\n", -1)
      dropped = lines.size - max_lines

      result = if dropped.positive?
        (lines.last(max_lines) + ["…[truncated #{dropped} lines]"]).join("\n")
      else
        stripped
      end

      (result.length > max_chars) ? result[-max_chars..] : result
    end
  end
end
