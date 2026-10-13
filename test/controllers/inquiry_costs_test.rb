require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class InquiryCostsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    travel_to Time.zone.local(2026, 10, 14, 10)
    @claims["exp"] = 1.hour.from_now.to_i
  end

  test "report requires the existing signed in access" do
    get inquiry_costs_path
    assert_redirected_to sign_in_path
  end

  test "Channels links to the aggregate daily report and the report shows no contact data" do
    sign_in
    get channels_path
    assert_select "a[href=?]", inquiry_costs_path, text: "Cost per inquiry"
    lead = Lead.create!(name: "Private synthetic contact", email: "private-contact@example.test",
      phone: "+14155550123", message: "Private synthetic message", source: "google_ads", capture_channel: "website_form",
      received_at: Time.zone.local(2026, 10, 13, 10), metadata: { "attribution" => { "campaign_id" => "123", "ad_id" => "456" } })
    DailyAdSpend.record!(spent_on: Date.new(2026, 10, 13), source: "google_ads", campaign_id: "123",
      campaign_name: "Nepal", currency: "USD", amount_minor: 3000)
    DailyAdSpend.record!(spent_on: Date.new(2026, 10, 13), source: "google_ads", campaign_id: "123",
      campaign_name: "Nepal", currency: "USD", amount_minor: 2000, ad_id: "456", ad_name: "Test ad")
    get inquiry_costs_path(start_date: "2026-10-13", end_date: "2026-10-13")
    assert_response :success
    assert_select "h1", text: "Cost per inquiry"
    assert_select "section[aria-label='Campaigns by day'] tbody tr", count: 1
    assert_select "section[aria-label='Campaigns by day'] td", text: "$30.00 USD", count: 2
    assert_select "section[aria-label='Ads by day'] td", text: "$20.00 USD", count: 2
    assert_select "section[aria-label='Ads by day'] td", text: /Test ad/
    assert_select "a[href=?]", channels_path, text: "Channels"
    [ lead.name, lead.email, lead.phone, lead.message, lead.reference ].each { |text| assert_not_includes response.body, text }
    assert_not_includes response.body, "\u2014"
  end

  test "unknown counts and no-data views are explicit" do
    sign_in
    Lead.create!(name: "Synthetic unknown source", source: "website_form", capture_channel: "website_form",
      received_at: Time.zone.local(2026, 10, 13, 10))
    get inquiry_costs_path(start_date: "2026-10-13", end_date: "2026-10-13")
    assert_response :success
    assert_select "section[aria-label='By day'] tbody tr", count: 3
    assert_select ".hint", text: "0 matched; 1 unassigned", count: 2
    assert_select "section[aria-label='Campaigns by day'] p", text: /No paid campaign data/
    assert_select "section[aria-label='Ads by day'] p", text: /No paid ad data/
  end

  [ "missing", "ambiguous" ].each do |campaign_state|
    test "multi-day report preserves ads with #{campaign_state} campaigns as unknown" do
      sign_in
      AdSpend::SOURCES.each do |source|
        if campaign_state == "ambiguous"
          [ "123", "999" ].each do |id|
            DailyAdSpend.record!(spent_on: Date.new(2026, 10, 13), source: source,
              campaign_id: id, campaign_name: "Shared name", currency: "USD", amount_minor: 1000)
          end
        end
        Lead.create!(name: "Synthetic unresolved campaign", source: source, capture_channel: "website_form",
          received_at: Time.zone.local(2026, 10, 13, 10),
          campaign_name: campaign_state == "ambiguous" ? "Shared name" : nil,
          metadata: { "attribution" => { "ad_id" => "456" } })
      end

      get inquiry_costs_path
      assert_response :success
      campaigns = css_select("section[aria-label='Campaigns by day'] tbody tr")
      assert_select "section[aria-label='Ads by day'] tbody tr", count: 14 do |rows|
        rows.each do |row|
          cells = row.css("td").map { |cell| cell.text.strip }
          assert_equal "Unknown", cells[2]
          assert_equal "Ad 456", cells[3]
          assert_equal "Unknown", cells[4]
          assert_equal "Unknown", cells[6]
          assert_equal row.at_css("time")["datetime"] == "2026-10-13" ? "1" : "0", cells[5]
          day = row.at_css("time")["datetime"]
          parent = campaigns.find do |campaign|
            campaign.at_css("time")["datetime"] == day &&
              campaign.css("td")[1].text.strip == cells[1] && campaign.css("td")[2].text.strip == "Unknown"
          end
          assert parent, "Missing unresolved campaign parent for #{cells[1]} on #{day}"
          assert_equal "Unknown", parent.css("td")[3].text.strip
        end
      end
    end
  end

  test "invalid date and shape returns a helpful bounded report" do
    sign_in
    [ { start_date: "2026-09-01", end_date: "2026-10-13" }, { start_date: "2026-10-14" },
      { start_date: "2026-02-30" }, { start_date: "2026-287" }, { start_date: [ "2026-10-13" ] },
      { start_date: "2026-10-13", end_date: "2026-10-12" } ].each do |params|
      get inquiry_costs_path, params: params
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: "Choose up to 31 complete days within the last two years."
    end
  end
end
