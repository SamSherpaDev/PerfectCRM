# Microsoft 365 delegated OAuth for the captain's mailbox.
#
# Rationale (standing decision): delegated access is inherently limited to
# the captain's own mailbox, needs no tenant-wide Mail.Read grant and no
# Exchange application access policy, and suits a single-operator tenant.
# Application permissions are deliberately not used.
#
# Scopes: offline_access (refresh token) + Mail.Read (read mail) +
# User.Read (the /me check behind Test connection and the account pin).
#
# The authorization-code flow runs on demand from Settings: "Connect
# mailbox" sends the captain to Microsoft, and /auth/microsoft/callback
# exchanges the code. The grant is only stored once /me confirms it belongs
# to MAILBOX_ADDRESS, so approving while signed in to another Microsoft
# account fails loudly instead of syncing nothing forever. Only the refresh
# token is persisted (encrypted on Setting); access tokens are fetched on
# demand and kept in memory. Every refresh persists a rotated refresh token
# when Microsoft returns one.
module Mail
  module GraphAuth
    AUTHORIZE_HOST = "https://login.microsoftonline.com"
    SCOPES = %w[offline_access Mail.Read User.Read].freeze

    class << self
      def configured?
        client_id.present? && client_secret.present? && tenant_id.present?
      end

      def client_id
        ENV.fetch("MS_GRAPH_CLIENT_ID", "").to_s.strip
      end

      def client_secret
        ENV.fetch("MS_GRAPH_CLIENT_SECRET", "").to_s.strip
      end

      def tenant_id
        ENV.fetch("MS_GRAPH_TENANT_ID", "").to_s.strip
      end

      def authorization_url(redirect_uri:, state:)
        raise NotConfiguredError, "Add MS_GRAPH_CLIENT_ID, MS_GRAPH_CLIENT_SECRET and MS_GRAPH_TENANT_ID first." unless configured?

        params = {
          client_id: client_id, response_type: "code", redirect_uri: redirect_uri,
          response_mode: "query", scope: SCOPES.join(" "), state: state
        }
        "#{AUTHORIZE_HOST}/#{tenant_id}/oauth2/v2.0/authorize?#{URI.encode_www_form(params)}"
      end

      # Exchanges the callback code and connects the mailbox, replacing any
      # previous grant. Refuses an account other than MAILBOX_ADDRESS and
      # stores nothing in that case. Clears the last mailbox error on success.
      def connect!(code:, redirect_uri:, transport: GraphTransport.new)
        tokens = post_token(transport,
          grant_type: "authorization_code", code: code,
          redirect_uri: redirect_uri, scope: SCOPES.join(" "))
        raise ConnectionError, "Microsoft returned no refresh token" if tokens[:refresh_token].blank?

        verify_mailbox!(transport, tokens[:access_token])
        ::Setting.current.update!(
          ms_graph_refresh_token: tokens[:refresh_token],
          ms_graph_connected_at: Time.current,
          mailbox_last_error: nil, mailbox_last_error_at: nil
        )
        tokens
      end

      # Fresh access token for one sync/import/test run. Persists a rotated
      # refresh token every time Microsoft returns one.
      def access_token!(transport: GraphTransport.new)
        raise NotConfiguredError, "Add MS_GRAPH_CLIENT_ID, MS_GRAPH_CLIENT_SECRET and MS_GRAPH_TENANT_ID first." unless configured?

        refresh_token = ::Setting.current.ms_graph_refresh_token.to_s
        raise NotConfiguredError, "Connect the mailbox in Settings first." if refresh_token.blank?

        tokens = post_token(transport,
          grant_type: "refresh_token", refresh_token: refresh_token, scope: SCOPES.join(" "))
        if tokens[:refresh_token].present? && tokens[:refresh_token] != refresh_token
          ::Setting.current.update!(ms_graph_refresh_token: tokens[:refresh_token])
        end
        tokens[:access_token]
      end

      private

      # The one mailbox this CRM reads. Microsoft happily hands a refresh
      # token for whichever account approved the consent screen, so the
      # grant is discarded unless /me is that mailbox.
      def verify_mailbox!(transport, access_token)
        me = GraphClient.new(transport: transport) { access_token }
          .get_json("/me", params: { "$select" => "id,mail,userPrincipalName" })
        addresses = [ me["mail"], me["userPrincipalName"] ]
          .map { |value| value.to_s.strip.downcase }.reject(&:blank?)
        return if addresses.include?(Mail.mailbox_address)

        signed_in = addresses.first.presence || "an unknown account"
        raise WrongMailboxError,
          "Microsoft signed in as #{signed_in}, not #{Mail.mailbox_address}. " \
          "The connection was refused. Sign out of Microsoft, then connect again as #{Mail.mailbox_address}."
      end

      def token_url
        "#{AUTHORIZE_HOST}/#{tenant_id}/oauth2/v2.0/token"
      end

      def post_token(transport, params)
        response = transport.post_form(token_url,
          { client_id: client_id, client_secret: client_secret, **params })
        body = response.json
        case response.status
        when 200
          { access_token: body["access_token"].to_s, refresh_token: body["refresh_token"].to_s,
            expires_in: body["expires_in"].to_i }
        when 400, 401
          if body["error"].to_s == "invalid_grant"
            raise GrantRevokedError, "Mailbox access was revoked or expired. Reconnect the mailbox in Settings."
          end
          raise ConnectionError, "Microsoft refused the token request (#{body["error"].presence || response.status})"
        else
          raise ConnectionError, "Microsoft token endpoint returned #{response.status}"
        end
      end
    end
  end
end
