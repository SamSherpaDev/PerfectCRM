# frozen_string_literal: true

# Versioned prompts under source control. The version string is logged on
# every call (see AiCall) so later tuning can compare prompt generations.
module Ai
  module Prompts
    CONFIG_PATH = Rails.root.join("config/ai_prompts.yml").freeze

    def self.config
      @config ||= YAML.load_file(CONFIG_PATH)
    end

    def self.version
      config.fetch("version").to_s
    end

    def self.system
      config.fetch("system").to_s
    end

    def self.render(key, vars = {})
      entry = config.fetch("prompts").fetch(key.to_s)
      template = entry.fetch("user_template").to_s
      body = vars.reduce(template) do |out, (name, value)|
        out.gsub("%{#{name}}", value.to_s)
      end
      system_extra = entry["system_addition"].to_s
      [ [ system, system_extra ].reject(&:blank?).join("\n\n"), body ]
    end

    def self.reset!
      @config = nil
    end
  end
end
