"""Google OIDC (authorization code flow). Tests substitute a fake provider."""
from urllib.parse import urlencode

import httpx
from google.auth.transport import requests as g_requests
from google.oauth2 import id_token

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"


class GoogleError(Exception):
    pass


class GoogleProvider:
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str):
        self.client_id, self.client_secret, self.redirect_uri = client_id, client_secret, redirect_uri

    def authorization_url(self, state: str) -> str:
        return AUTH_URL + "?" + urlencode({
            "client_id": self.client_id, "redirect_uri": self.redirect_uri, "response_type": "code",
            "scope": "openid email profile", "state": state, "prompt": "select_account"})

    def exchange(self, code: str) -> dict:
        """Returns verified claims: sub, email, email_verified, name."""
        r = httpx.post(TOKEN_URL, data={
            "code": code, "client_id": self.client_id, "client_secret": self.client_secret,
            "redirect_uri": self.redirect_uri, "grant_type": "authorization_code"}, timeout=10)
        if r.status_code != 200:
            raise GoogleError("token exchange failed")
        try:
            # verifies signature, issuer, audience and expiry
            claims = id_token.verify_oauth2_token(r.json()["id_token"], g_requests.Request(), self.client_id)
        except Exception as e:
            raise GoogleError(f"invalid id_token: {e}")
        if not claims.get("email_verified"):
            raise GoogleError("email not verified")
        return {"sub": claims["sub"], "email": claims["email"],
                "name": claims.get("name") or claims["email"].split("@")[0]}
