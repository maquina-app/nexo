Nexo.configure do |config|
  # Provider-neutral: any ruby_llm-supported model. There is intentionally no default.
  config.default_model = ENV["NEXO_MODEL"]
  config.default_sandbox = :virtual      # :virtual | :local  (:remote in Spec 4)
  config.default_permissions = :read_only # :read_only | :auto | :ask
  config.skills_path = Rails.root.join("app/skills")

  # Background execution (Spec 11): MyWorkflow.run_later(payload) enqueues on your
  # existing ActiveJob adapter. Route workflow jobs to a dedicated queue (nil uses
  # ActiveJob's default queue):
  # config.job_queue = :nexo

  # Live progress over Turbo Streams (opt-in; requires turbo-rails). Runs broadcast
  # their events as `nexo.workflow.event` notifications regardless; set this to true
  # to also mirror them over Turbo (override app/views/nexo/_event.html.erb to style
  # them). Without Turbo this is a no-op — subscribe to the notifications yourself
  # for logging/metrics.
  # config.broadcast_events = true
end
