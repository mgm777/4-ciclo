"""Testes do self-healer: autenticação, filtros de segurança e cooldown.
As chamadas à API do Kubernetes e ao Discord são mockadas."""
import os
from unittest.mock import patch

os.environ["SELF_HEALER_TOKEN"] = "test-token"
os.environ["COOLDOWN_SECONDS"] = "300"

import app as healer  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}


def alert(job="auth-service", status="firing"):
    return {"status": status, "labels": {"alertname": "HTTP5xxErrorRateHigh", "job": job},
            "annotations": {"summary": "5xx alto"}}


def post(client, alerts, headers=AUTH):
    return client.post("/hooks/grafana", json={"receiver": "x", "status": "firing", "alerts": alerts},
                       headers=headers)


def setup_function():
    healer._last_action.clear()


def test_health():
    assert healer.app.test_client().get("/health").status_code == 200


def test_rejects_missing_or_wrong_token():
    c = healer.app.test_client()
    assert post(c, [alert()], headers={}).status_code == 401
    assert post(c, [alert()], headers={"Authorization": "Bearer errado"}).status_code == 401


@patch.object(healer, "rollout_restart")
def test_ignores_resolved_alerts(restart):
    r = post(healer.app.test_client(), [alert(status="resolved")])
    assert r.get_json()["results"][0]["action"] == "ignored"
    restart.assert_not_called()


@patch.object(healer, "rollout_restart")
def test_ignores_deployments_outside_allowlist(restart):
    r = post(healer.app.test_client(), [alert(job="kube-dns")])
    assert r.get_json()["results"][0]["reason"] == "not_in_allowlist"
    restart.assert_not_called()


@patch.object(healer, "notify_discord")
@patch.object(healer, "wait_rollout")
@patch.object(healer, "rollout_restart", return_value=7)
def test_restarts_then_respects_cooldown(restart, _wait, _discord):
    c = healer.app.test_client()
    first = post(c, [alert()]).get_json()["results"][0]
    assert first == {"deployment": "auth-service", "action": "rollout_restart", "generation": 7}
    restart.assert_called_once_with("auth-service")

    second = post(c, [alert()]).get_json()["results"][0]
    assert second["action"] == "skipped" and second["reason"] == "cooldown"
    assert restart.call_count == 1


@patch.object(healer, "rollout_restart")
def test_dry_run_does_not_touch_cluster(restart):
    with patch.object(healer, "DRY_RUN", True):
        r = post(healer.app.test_client(), [alert()])
    assert r.get_json()["results"][0]["action"] == "dry_run"
    restart.assert_not_called()
