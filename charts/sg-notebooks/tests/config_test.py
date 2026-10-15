# Runs the hub's Seagit extraConfig (from the rendered values) inside the real hub image and checks
# the authenticator, profiles, spot affinity and environment it produces, for all three sign-in
# modes. OIDC discovery is answered by a local stub issuer. Driven by config_test.sh.
import http.server
import json
import sys
import threading
import types

import yaml
from traitlets.config import Config

values = yaml.safe_load(open(sys.argv[1]))
code = values["jupyterhub"]["hub"]["extraConfig"]["seagit"]


class Stub(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        base = "http://127.0.0.1:%d" % self.server.server_port
        body = json.dumps({
            "issuer": base,
            "authorization_endpoint": base + "/authorize",
            "token_endpoint": base + "/token",
            "userinfo_endpoint": base + "/userinfo",
        }).encode()
        self.send_response(200 if self.path == "/.well-known/openid-configuration" else 404)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Stub)
threading.Thread(target=srv.serve_forever, daemon=True).start()
issuer = "http://127.0.0.1:%d" % srv.server_port


def run(custom):
    cfg = {"custom": custom}

    def get_config(key, default=None):
        v = cfg
        for part in key.split("."):
            if not isinstance(v, dict) or part not in v:
                return default
            v = v[part]
        return v

    sys.modules["z2jh"] = types.SimpleNamespace(get_config=get_config)
    c = Config()
    exec(code, {"c": c})
    return c


def check(cond, msg):
    if not cond:
        print("FAIL: " + msg)
        sys.exit(1)


base = values["jupyterhub"]["custom"]
auth = dict(base["auth"], admins="alice, ops", allowedUsers="bob,carol",
            adminPassword="A" * 43, userPassword="B" * 43)

# password
c = run(dict(base, auth=auth, sizes="medium,small", images="pytorch,scipy", bucket="b1", region="eu-west-1"))
check(c.JupyterHub.authenticator_class == "shared-password", "password: authenticator")
check(c.SharedPasswordAuthenticator.admin_password == "A" * 43, "password: admin password")
check(c.Authenticator.allowed_users == {"bob", "carol", "alice", "ops"}, "password: allowed users = team + admins")


def password_allowed(custom_auth, username):
    """What the hub decides for `username` at sign-in, with JupyterHub's own check_allowed."""
    from jupyterhub.authenticators.shared import SharedPasswordAuthenticator

    a = SharedPasswordAuthenticator(config=run(dict(base, auth=custom_auth)))
    return a.check_allowed(username, None)


# no team usernames (the wizard leaves it optional): the admins can still sign in, nobody else
solo = dict(auth, allowedUsers="")
check(run(dict(base, auth=solo)).Authenticator.allowed_users == {"alice", "ops"}, "password: no team -> admins only")
check(password_allowed(solo, "alice"), "password: admin allowed with no team usernames")
check(not password_allowed(solo, "mallory"), "password: others refused with no team usernames")
check(password_allowed(auth, "ops") and password_allowed(auth, "bob"), "password: admin and team allowed")
check(c.Authenticator.admin_users == {"alice", "ops"}, "password: admins")
p = c.KubeSpawner.profile_list
check([x["slug"] for x in p] == ["medium", "small"], "profiles order")
check(p[0]["default"] and not p[1]["default"], "first size is the default")
check(p[0]["kubespawner_override"]["cpu_limit"] == 2 and p[0]["kubespawner_override"]["mem_limit"] == "8G", "medium size")
ch = p[0]["profile_options"]["image"]["choices"]
check(list(ch) == ["pytorch", "scipy"] and ch["pytorch"]["default"], "image choices")
check(ch["scipy"]["kubespawner_override"]["image"].startswith("quay.io/jupyter/scipy-notebook:"), "image ref")
check(c.KubeSpawner.node_affinity_required[0]["matchExpressions"][0]["values"] == ["spot"], "spot affinity")
check(c.KubeSpawner.automount_service_account_token is False, "no API token")
env = c.KubeSpawner.environment.get_value({})
check(env["SEAGIT_BUCKET"] == "b1" and env["SEAGIT_BUCKET_URI"] == "s3://b1/" and env["AWS_REGION"] == "eu-west-1", "env")
check(env["SEAGIT_PREFIX"] == "", "new bucket: whole bucket, whatever the stack prefix says")

# existing bucket: only the folder
c = run(dict(base, auth=auth, bucket="theirs", bucketMode="existing", prefix="seagit-backups/nb1/", region="us-east-1"))
env = c.KubeSpawner.environment.get_value({})
check(env["SEAGIT_BUCKET_URI"] == "s3://theirs/seagit-backups/nb1/" and env["SEAGIT_PREFIX"] == "seagit-backups/nb1/", "existing bucket folder")

# custom team image next to a catalog one
c = run(dict(base, auth=auth, images="scipy,custom", customImage="123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0"))
ch = c.KubeSpawner.profile_list[0]["profile_options"]["image"]["choices"]
check(ch["custom"]["kubespawner_override"]["image"] == "123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0" and ch["custom"]["display_name"] == "Team image", "custom choice")

c = run(dict(base, auth=auth, sizes="xsmall,small"))
x = c.KubeSpawner.profile_list[0]
check(x["slug"] == "xsmall" and x["kubespawner_override"]["mem_guarantee"] == "512M" and x["kubespawner_override"]["cpu_limit"] == 0.5, "xsmall size")

# custom image + avoidSpot off
c = run(dict(base, auth=auth, images="123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0", avoidSpot=False))
ch = c.KubeSpawner.profile_list[0]["profile_options"]["image"]["choices"]
only = list(ch.values())[0]
check(only["kubespawner_override"]["image"] == "123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0", "custom image")
check("node_affinity_required" not in c.KubeSpawner, "avoidSpot=false: no affinity")

# github
gh = dict(auth, type="github", clientId="cid", clientSecret="cs", callbackUrl="https://h/hub/oauth_callback",
          github={"organizations": "acme, acme:data-science"})
c = run(dict(base, auth=gh))
check(c.JupyterHub.authenticator_class == "github", "github: authenticator")
check(c.GitHubOAuthenticator.allowed_organizations == {"acme", "acme:data-science"}, "github: orgs")
check(c.GitHubOAuthenticator.oauth_callback_url == "https://h/hub/oauth_callback", "github: callback")
check("read:org" in c.GitHubOAuthenticator.scope, "github: read:org scope")

# oidc with groups
oi = dict(auth, type="oidc", clientId="cid", clientSecret="cs", callbackUrl="https://h/hub/oauth_callback",
          oidc={"issuer": issuer + "/", "usernameClaim": "email", "groupsClaim": "groups",
                "allowedGroups": "ds-notebooks", "adminGroups": "ds-admins", "extraScopes": "groups"})
c = run(dict(base, auth=oi))
g = c.GenericOAuthenticator
check(c.JupyterHub.authenticator_class == "generic-oauth", "oidc: authenticator")
check(g.authorize_url == issuer + "/authorize" and g.token_url == issuer + "/token" and g.userdata_url == issuer + "/userinfo", "oidc: discovery")
check(g.scope == ["openid", "email", "profile", "groups"], "oidc: scopes")
check(g.allowed_groups == {"ds-notebooks"} and g.admin_groups == {"ds-admins"}, "oidc: groups")
check(g.auth_state_groups_key == "oauth_user.groups" and g.manage_groups is True, "oidc: groups claim")
check(g.username_claim == "email", "oidc: username claim")
check("allow_all" not in g, "oidc: groups set, so not allow_all")

# oidc without groups = anyone the provider signs in
c = run(dict(base, auth=dict(oi, oidc=dict(oi["oidc"], allowedGroups="", adminGroups=""))))
check(c.GenericOAuthenticator.allow_all is True, "oidc: no groups -> allow_all")

# The config must also load in the real authenticator classes (trait types and names). The spawner
# needs a cluster, so kind_test.sh covers it.
from jupyterhub.authenticators.shared import SharedPasswordAuthenticator
from oauthenticator.generic import GenericOAuthenticator
from oauthenticator.github import GitHubOAuthenticator

SharedPasswordAuthenticator(config=run(dict(base, auth=auth)))
GitHubOAuthenticator(config=run(dict(base, auth=gh)))
GenericOAuthenticator(config=run(dict(base, auth=oi)))
print("PASS")
