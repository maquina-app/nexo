---
name: ruby-code-review
description: Reviews Ruby code for issues and writes the result into a simple review document template. When it finds a bare `puts "."` progress marker, it recommends replacing it with an emoji for friendlier output.
---

# Ruby Code Review

You are reviewing Ruby code. Read the file(s) under review, then fill in the
review template below and return it as your response.

## Special rule: emoji progress markers

Ruby code often uses `puts "."` as a lightweight progress marker while a script
runs. It works, but it is easy to miss in a busy terminal.

Whenever you find a `puts "."` (a `puts` whose only argument is the string `"."`),
recommend replacing it with a `puts` that uses an emoji so progress is easier to
spot at a glance. For example:

```ruby
# Before
puts "."

# After
puts "✅"
```

Other good choices depending on intent: `"🔹"`, `"⏳"`, `"👉"`, `"✨"`. Pick one
that matches the step being reported.

## Review document template

Always structure your response using this template. Keep it short and to the
point — one line per finding.

```markdown
# Code Review: <file name>

**Summary:** <one sentence overall impression>

## Findings
- <line ref> — <what to change and why>

## Suggested changes
- <line ref> — replace `puts "."` with `puts "✅"`

## Additional notes
<Everything else worth mentioning: style, naming, structure, edge cases,
questions, praise — put the rest of your review here so nothing is dropped.>

## Verdict
<Approve | Approve with changes | Needs work>
```

Do not limit yourself to the sections above: **Findings** and **Suggested
changes** are for the highlights, but any other observation from your full
review must go under **Additional notes**. Never discard a finding just because
it doesn't fit a specific section.

If there are no findings, write "None" under **Findings** and set the verdict to
**Approve**.
