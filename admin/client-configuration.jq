def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
def positive: type == "number" and . > 0 and floor == .;
def optional_seconds: . == null or positive;
def host: type == "string" and test("^[A-Za-z0-9.-]+$");
def setting($name; $default): if $settings | has($name) then $settings[$name] else $default end;
if ($settings | type != "object") or
  (($settings | keys) - ["signInSessionLifetime", "gatewaySignInFlow", "bearerToken", "redirectPort", "additionalRedirectReferrerHosts", "artifactPreviewIframeOrigin", "customInferenceHeaders", "streamIdleTimeout"] | length > 0)
then error("Client settings file contains unsupported fields") else . end |
{
  provider: "gateway",
  credentialKind: "interactive_sign_in",
  gatewayUrl: $url,
  signInSessionLifetime: setting("signInSessionLifetime"; null),
  gatewaySignInFlow: setting("gatewaySignInFlow"; "browser"),
  gatewaySso: {
    clientId: $client,
    issuerUrl: ("https://login.microsoftonline.com/" + $tenant + "/v2.0"),
    bearerToken: setting("bearerToken"; "access_token"),
    scopes: ($scopes | split(" ") | map(select(length > 0)) | join(" ")),
    redirectPort: setting("redirectPort"; null),
    additionalRedirectReferrerHosts: setting("additionalRedirectReferrerHosts"; [])
  },
  artifactPreviewIframeOrigin: setting("artifactPreviewIframeOrigin"; null),
  customInferenceHeaders: setting("customInferenceHeaders"; {}),
  streamIdleTimeout: setting("streamIdleTimeout"; 300),
  models: {opus: $opus, sonnet: $sonnet, haiku: $haiku}
} |
if ($tenant | guid) and (.gatewaySso.clientId | guid) and
  (.gatewayUrl | test("^https://[A-Za-z0-9.-]+(:[0-9]+)?/anthropic$")) and
  (.signInSessionLifetime | optional_seconds) and
  (.gatewaySignInFlow == "browser") and
  (.gatewaySso.bearerToken == "access_token" or .gatewaySso.bearerToken == "id_token") and
  (.gatewaySso.scopes | split(" ") | all(.[]; test("^(openid|profile|email|offline_access|(api://|https://)[A-Za-z0-9./:_-]+/[^/ ]+)$"))) and
  (.gatewaySso.scopes | split(" ") | map(select(startswith("api://") or startswith("https://")) | sub("/[^/]+$"; "")) | unique | length == 1) and
  (. as $config | [.gatewaySso.scopes | split(" ")[] | select(startswith("api://")) | sub("/[^/]+$"; "")] | all(.[]; . != ("api://" + $config.gatewaySso.clientId))) and
  (.gatewaySso.redirectPort | . == null or (positive and . <= 65535)) and
  (.gatewaySso.additionalRedirectReferrerHosts | type == "array" and all(.[]; host)) and
  (.artifactPreviewIframeOrigin | . == null or (type == "string" and test("^https://[A-Za-z0-9.-]+(:[0-9]+)?$"))) and
  (.customInferenceHeaders | type == "object" and all(to_entries[];
    (.key | test("^[A-Za-z0-9-]+$") and (ascii_downcase | test("authorization|api-key|token|cookie|secret") | not)) and
    (.value | type == "string" and (test("[\r\n]") | not)))) and
  (.streamIdleTimeout | positive) and
  ([.models[]] | all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
then . else error("Invalid client settings: check OIDC IDs/scopes, URL, optional ports/seconds, model names and non-credential headers") end