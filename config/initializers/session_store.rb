Rails.application.config.x.staff_session_idle_timeout = 30.days

Rails.application.config.session_store :cookie_store,
  key: "_perfectcrm_session", secure: Rails.env.production?, httponly: true,
  same_site: :lax, expire_after: Rails.application.config.x.staff_session_idle_timeout
