Nexo.configure do |config|
  # Provider-neutral: any ruby_llm-supported model. There is intentionally no default.
  config.default_model = ENV["NEXO_MODEL"]
  config.default_sandbox = :virtual      # :virtual | :local  (:remote in Spec 4)
  config.default_permissions = :read_only # :read_only | :auto | :ask
  config.skills_path = Rails.root.join("app/skills")
end
