require "application_system_test_case"

# The captain answers clients from his phone: creating a template, previewing
# it, and inserting a placeholder must all work one-handed at 390px.
class TemplatesTest < ApplicationSystemTestCase
  setup do
    @key = OpenSSL::PKey::RSA.generate(2048)
    @source = Google::Auth::IDTokens::StaticKeySource.from_jwk_set(
      { keys: [ JWT::JWK.new(@key.public_key).export.merge(alg: "RS256") ] }
    )
    ENV["ALLOWED_GOOGLE_EMAILS"] = "captain@gmail.com"
    ENV["GOOGLE_CLIENT_ID"] = "test-client"
    OmniAuth.config.test_mode = true
    @claims = { "sub" => "google-captain", "email" => "captain@gmail.com", "name" => "Captain",
                "email_verified" => true, "aud" => "test-client", "iss" => "https://accounts.google.com",
                "exp" => 1.hour.from_now.to_i }
  end

  teardown do
    OmniAuth.config.mock_auth.delete(:google_oauth2)
  end

  test "create with live preview and placeholder insert at 390px" do
    sign_in_through_google
    page.current_window.resize_to(390, 844)

    visit templates_path
    assert_no_overflow
    within(".page-actions") { click_link "New template" }

    fill_in "Name", with: "Deposit nudge"
    select "Deposit nudge", from: "Kind of message"
    fill_in "Subject", with: "Holding your {{trip}} seats"
    fill_in "Body", with: "Hi {{first_name}}, please send {{deposit_due}}."

    # The preview pane fills from the sample context without saving.
    within("#template_preview") do
      assert_text "Maya"
      assert_text "$500.00"
      assert_text "Everest Base Camp trek"
    end

    # The chooser drops the token where the cursor sits (end of the body).
    click_button "{{balance_due}}"
    assert_equal "Hi {{first_name}}, please send {{deposit_due}}.{{balance_due}}",
      find_field("Body").value
    within("#template_preview") do
      assert_text "$1,850.00"
    end

    # Focusing the subject first sends the next token there instead (at the
    # click position, proving true cursor insertion rather than appending).
    find_field("Subject").click
    click_button "{{invoice_number}}"
    subject = find_field("Subject").value
    assert_includes subject, "{{invoice_number}}"
    assert_includes subject, "Holding your"
    assert_includes subject, "seats"

    click_button "Create template"
    assert_text "Template saved."
    assert_text "Deposit nudge"
    assert_no_overflow
  end

  test "picker inserts one-handed at 390px and counts the use" do
    Template.create!(name: "Deposit nudge", purpose: "deposit_nudge",
      subject: "Your {{trip}} deposit", body: "Hi {{first_name}}.")
    sign_in_through_google
    page.current_window.resize_to(390, 844)

    visit picker_templates_path
    assert_no_overflow
    assert_button "Insert"
    click_button "Insert"
    assert_selector "button", text: /Inserted/, wait: 5

    visit templates_path
    assert_text "Used once"
    assert_no_overflow
  end

  test "removed member URLs return not found while the editor still previews" do
    template = Template.create!(name: "Route check", body: "Hello")
    sign_in_through_google
    visit edit_template_path(template)
    fill_in "Body", with: "Welcome {{first_name}}"
    within("#template_preview") { assert_text "Welcome Maya" }
    [ template_path(template), "#{template_path(template)}/preview" ].each do |path|
      status = page.evaluate_async_script(<<~JS, path)
        const done = arguments[arguments.length - 1]
        fetch(arguments[0]).then(response => done(response.status))
      JS
      assert_equal 404, status, path
    end
  end

  test "stale picker reports a real missing template response and allows retry" do
    template = Template.create!(name: "Retry template", purpose: "deposit_nudge", body: "Hello")
    attributes = template.attributes
    sign_in_through_google
    page.current_window.resize_to(390, 844)
    visit picker_templates_path
    assert_button "Insert"
    template.destroy!

    click_button "Insert"
    assert_selector "[role='alert']", text: "Could not insert template. Please try again."
    assert_button "Insert", disabled: false
    capture_evidence("picker-error-mobile")

    restored = Template.create!(attributes)
    click_button "Insert"
    assert_selector "button", text: /Inserted/
    assert_no_text "Could not insert template. Please try again."
    assert_equal 1, restored.reload.usage_count
    capture_evidence("picker-retry-mobile")
  end

  %w[http network json].each do |failure|
    test "picker reports #{failure} failures and allows retry" do
      template = Template.create!(name: "Retry template", purpose: "deposit_nudge", body: "Hello")
      sign_in_through_google
      visit picker_templates_path
      assert_button "Insert"
      page.execute_script(<<~JS, failure)
        const failure = arguments[0]
        const originalFetch = window.fetch
        window.fetch = (...args) => {
          window.fetch = originalFetch
          if (failure === "network") return Promise.reject(new TypeError("Offline"))
          return Promise.resolve(new Response(failure === "json" ? "invalid" : "Unavailable", {
            status: failure === "http" ? 503 : 200
          }))
        }
      JS

      click_button "Insert"
      assert_selector "[role='alert']", text: "Could not insert template. Please try again."
      assert_button "Insert", disabled: false
      assert_equal 0, template.reload.usage_count

      click_button "Insert"
      assert_selector "button", text: /Inserted/
      assert_no_text "Could not insert template. Please try again."
      assert_equal 1, template.reload.usage_count
    end
  end

  test "preview ignores older response bodies arriving after the current preview" do
    sign_in_through_google
    visit new_template_path
    assert_field "Subject"
    page.execute_script <<~JS
      window.previewBodies = []
      const originalFetch = window.fetch.bind(window)
      window.fetch = async (...args) => {
        const response = await originalFetch(...args)
        const html = await response.text()
        return {
          ok: response.ok,
          text: () => new Promise(resolve => {
            window.previewBodies.push(() => resolve(html))
            document.documentElement.dataset.previewRequests = window.previewBodies.length
          })
        }
      }
    JS

    fill_in "Subject", with: "Earlier wording"
    assert_selector "html[data-preview-requests='1']"
    fill_in "Subject", with: "Current wording"
    assert_selector "html[data-preview-requests='2']"
    page.execute_script "window.previewBodies[1]()"
    within("#template_preview") { assert_text "Current wording" }
    page.evaluate_async_script <<~JS
      const done = arguments[0]
      window.previewBodies[0]()
      requestAnimationFrame(() => requestAnimationFrame(done))
    JS
    within("#template_preview") do
      assert_text "Current wording"
      assert_no_text "Earlier wording"
    end
  end

  test "maintain library and preview personal messages at 390px without sending" do
    load Rails.root.join("db/seeds/templates.rb")
    sign_in_through_google
    page.current_window.resize_to(390, 844)
    visit templates_path
    assert_equal 8, Template.active.count
    assert_no_overflow
    capture_evidence("library-mobile")
    template = Template.first
    visit edit_template_path(template)
    fill_in "Name", with: "Group greeting"
    fill_in "Subject", with: "Hello {{first_name}}"
    fill_in "Body", with: "Dear {{full_name}}, welcome aboard. {{unknown}}"
    within("#template_preview") do
      assert_text "Dear Maya"
      assert_text "unknown"
    end
    capture_evidence("editor-mobile")
    click_button "Save changes"
    assert_text "Template saved."
    within("[aria-label='Actions for Group greeting']") { click_button "Archive" }
    assert_text "Template archived."
    visit picker_templates_path
    assert_no_text "Group greeting"
    visit templates_path(tab: "archived")
    within("[aria-label='Actions for Group greeting']") { click_button "Restore" }
    assert_text "Template restored."

    visit merge_templates_path
    select "Group greeting", from: "Template"
    fill_in "Recipients", with: "Maya Gurung <maya@example.com>\nPemba Sherpa <pemba@example.com>"
    before_deliveries = ActionMailer::Base.deliveries.size
    click_button "Preview merge"
    assert_text "2 messages ready"
    assert_text "Dear Maya Gurung, welcome aboard."
    assert_text "Dear Pemba Sherpa, welcome aboard."
    assert_text "Nothing sent"
    assert_no_selector "input[type='submit'][value='Send']"
    assert_equal before_deliveries, ActionMailer::Base.deliveries.size
    assert_equal 0, template.reload.usage_count
    assert_no_overflow
    find("[aria-label='Merged messages']").scroll_to(:top)
    capture_evidence("merge-mobile")
    fill_in "Recipients", with: ""
    click_button "Preview merge"
    # Wait for the response's flash instead of reading the outgoing document.
    assert_selector "[role='status']", text: "Add at least one recipient email."
    assert_text "0 messages ready"
  end

  def capture_evidence(name)
    return unless ENV["TEMPLATE_EVIDENCE_DIR"].present?

    page.current_window.resize_to(390, page.evaluate_script("document.documentElement.scrollHeight") + 300)
    page.save_screenshot(File.join(ENV.fetch("TEMPLATE_EVIDENCE_DIR"), "#{name}.png"))
    page.current_window.resize_to(390, 844)
  end

  private

  def sign_in_through_google
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
    end
    assert_text "Today"
  end

  def assert_no_overflow
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{page.current_path} overflows a 390px viewport (#{width}px)"
  end
end
