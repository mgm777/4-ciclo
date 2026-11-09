"""
self-healer — Runbook Automation do ToggleMaster.

Recebe o webhook do Grafana Alerting e executa a ação corretiva do runbook
sem intervenção humana: o equivalente a

    kubectl rollout restart deployment/<serviço> -n togglemaster

(um PATCH na anotação kubectl.kubernetes.io/restartedAt do pod template, que é
exatamente o que o kubectl faz). Depois acompanha o rollout até os pods novos
ficarem prontos e publica o resultado no Discord.

Proteções contra "remediação em loop" (alert fatigue também vale para robôs):
  * só age em alertas com status "firing" e com o label `job` na allowlist;
  * cooldown por deployment (COOLDOWN_SECONDS): se o restart não resolveu, o
    problema não é de estado do pod e quem precisa agir é o plantonista
    (o incidente continua aberto no PagerDuty);
  * DRY_RUN=true registra a decisão sem tocar no cluster.

Autenticação: o Grafana envia `Authorization: Bearer <SELF_HEALER_TOKEN>`.
Acesso ao cluster: ServiceAccount própria, com uma Role que só permite
get/patch em deployments do namespace togglemaster.
"""
import hmac
import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify, request
from opentelemetry import metrics, trace

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("self-healer")

TARGET_NAMESPACE = os.getenv("TARGET_NAMESPACE", "togglemaster")
ALLOWED_DEPLOYMENTS = {d.strip() for d in os.getenv(
    "ALLOWED_DEPLOYMENTS",
    "auth-service,flag-service,targeting-service,evaluation-service,analytics-service",
).split(",") if d.strip()}
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "300"))
ROLLOUT_TIMEOUT_SECONDS = int(os.getenv("ROLLOUT_TIMEOUT_SECONDS", "180"))
DRY_RUN = os.getenv("DRY_RUN", "false").lower() == "true"
WEBHOOK_TOKEN = os.getenv("SELF_HEALER_TOKEN", "")
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "")

# Acesso in-cluster à API do Kubernetes com o token da ServiceAccount.
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_API = "https://{}:{}".format(
    os.getenv("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.getenv("KUBERNETES_SERVICE_PORT", "443"),
)

tracer = trace.get_tracer("self-healer")
meter = metrics.get_meter("self-healer")
actions_counter = meter.create_counter(
    "self_healer.actions",
    unit="{action}",
    description="Decisões do self-healer por deployment e resultado",
)

app = Flask(__name__)

_last_action = {}
_lock = threading.Lock()


def jlog(event, **fields):
    """Log estruturado (JSON numa linha) — fácil de filtrar no Loki/New Relic."""
    log.info(json.dumps({"event": event, **fields}, ensure_ascii=False))


def _k8s_session():
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {token}"
    s.verify = f"{SA_DIR}/ca.crt"
    return s


def notify_discord(title, description, color):
    if not DISCORD_WEBHOOK_URL:
        return
    payload = {
        "username": "ToggleMaster Self-Healer",
        "embeds": [{
            "title": title,
            "description": description,
            "color": color,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "footer": {"text": "Runbook Automation · self-healer"},
        }],
    }
    try:
        requests.post(DISCORD_WEBHOOK_URL, json=payload, timeout=5).raise_for_status()
    except requests.RequestException as e:
        jlog("discord_notify_failed", error=str(e))


def rollout_restart(deployment):
    """PATCH idêntico ao `kubectl rollout restart deployment/<name>`."""
    restarted_at = datetime.now(timezone.utc).isoformat()
    body = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": restarted_at,
        "togglemaster.io/restarted-by": "self-healer",
    }}}}}
    url = f"{K8S_API}/apis/apps/v1/namespaces/{TARGET_NAMESPACE}/deployments/{deployment}"
    resp = _k8s_session().patch(
        url, data=json.dumps(body),
        headers={"Content-Type": "application/strategic-merge-patch+json"}, timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["metadata"]["generation"]


def wait_rollout(deployment, generation, alertname, started):
    """Equivalente ao `kubectl rollout status`: espera os pods novos ficarem prontos."""
    url = f"{K8S_API}/apis/apps/v1/namespaces/{TARGET_NAMESPACE}/deployments/{deployment}"
    session = _k8s_session()
    deadline = time.time() + ROLLOUT_TIMEOUT_SECONDS
    status = {}
    while time.time() < deadline:
        try:
            d = session.get(url, timeout=10).json()
            spec_replicas = d["spec"].get("replicas", 1)
            status = d.get("status", {})
            done = (
                status.get("observedGeneration", 0) >= generation
                and status.get("updatedReplicas", 0) == spec_replicas
                and status.get("availableReplicas", 0) == spec_replicas
                and status.get("replicas", 0) == spec_replicas
            )
            if done:
                elapsed = round(time.time() - started, 1)
                jlog("rollout_completed", deployment=deployment, replicas=spec_replicas, seconds=elapsed)
                actions_counter.add(1, {"deployment": deployment, "result": "healed"})
                notify_discord(
                    f"✅ Self-healing concluído: {deployment}",
                    f"Alerta **{alertname}** → `kubectl rollout restart deployment/{deployment}`\n"
                    f"{spec_replicas}/{spec_replicas} pods novos prontos em **{elapsed}s**.\n"
                    "Se a taxa de erro normalizar, o alerta resolve sozinho no Grafana e no PagerDuty.",
                    0x2ECC71,
                )
                return
        except requests.RequestException as e:
            jlog("rollout_status_error", deployment=deployment, error=str(e))
        time.sleep(3)

    jlog("rollout_timeout", deployment=deployment, status=status)
    actions_counter.add(1, {"deployment": deployment, "result": "rollout_timeout"})
    notify_discord(
        f"⚠️ Self-healing sem sucesso: {deployment}",
        f"O rollout não ficou pronto em {ROLLOUT_TIMEOUT_SECONDS}s. Intervenção humana necessária "
        "(incidente segue aberto no PagerDuty).",
        0xE67E22,
    )


def handle_alert(alert):
    labels = alert.get("labels", {})
    alertname = labels.get("alertname", "?")
    deployment = labels.get("job") or labels.get("service") or ""

    with tracer.start_as_current_span("self-heal decide", attributes={
        "alert.name": alertname, "k8s.deployment.name": deployment,
    }) as span:
        if alert.get("status") != "firing":
            jlog("ignored", reason="status_not_firing", alertname=alertname, deployment=deployment)
            return {"deployment": deployment, "action": "ignored", "reason": "not_firing"}

        if deployment not in ALLOWED_DEPLOYMENTS:
            jlog("ignored", reason="not_in_allowlist", alertname=alertname, deployment=deployment)
            actions_counter.add(1, {"deployment": deployment or "unknown", "result": "not_allowed"})
            return {"deployment": deployment, "action": "ignored", "reason": "not_in_allowlist"}

        with _lock:
            now = time.time()
            last = _last_action.get(deployment, 0)
            if now - last < COOLDOWN_SECONDS:
                remaining = int(COOLDOWN_SECONDS - (now - last))
                jlog("skipped", reason="cooldown", deployment=deployment, remaining_seconds=remaining)
                actions_counter.add(1, {"deployment": deployment, "result": "cooldown"})
                span.set_attribute("self_healer.result", "cooldown")
                return {"deployment": deployment, "action": "skipped", "reason": "cooldown",
                        "remaining_seconds": remaining}
            _last_action[deployment] = now

        summary = alert.get("annotations", {}).get("summary", "")
        jlog("remediation_started", alertname=alertname, deployment=deployment, namespace=TARGET_NAMESPACE,
             runbook="kubectl rollout restart", dry_run=DRY_RUN, summary=summary)

        if DRY_RUN:
            actions_counter.add(1, {"deployment": deployment, "result": "dry_run"})
            return {"deployment": deployment, "action": "dry_run"}

        try:
            generation = rollout_restart(deployment)
        except requests.RequestException as e:
            jlog("remediation_failed", deployment=deployment, error=str(e))
            actions_counter.add(1, {"deployment": deployment, "result": "error"})
            span.record_exception(e)
            with _lock:
                _last_action.pop(deployment, None)  # falhou: permite nova tentativa
            return {"deployment": deployment, "action": "error", "error": str(e)}

        jlog("rollout_restart_executed", deployment=deployment, namespace=TARGET_NAMESPACE, generation=generation)
        span.set_attribute("self_healer.result", "restarted")
        notify_discord(
            f"🔧 Self-healing acionado: {deployment}",
            f"Alerta **{alertname}** disparou.\n{summary}\n\n"
            f"Executando `kubectl rollout restart deployment/{deployment} -n {TARGET_NAMESPACE}`…",
            0x3498DB,
        )
        threading.Thread(
            target=wait_rollout, args=(deployment, generation, alertname, time.time()), daemon=True,
        ).start()
        return {"deployment": deployment, "action": "rollout_restart", "generation": generation}


@app.route("/health")
def health():
    return jsonify({"status": "ok", "dry_run": DRY_RUN})


@app.route("/hooks/grafana", methods=["POST"])
def grafana_webhook():
    if not WEBHOOK_TOKEN:
        return jsonify({"error": "SELF_HEALER_TOKEN não configurado"}), 500
    auth = request.headers.get("Authorization", "")
    if not hmac.compare_digest(auth, f"Bearer {WEBHOOK_TOKEN}"):
        jlog("unauthorized", remote=request.remote_addr)
        return jsonify({"error": "não autorizado"}), 401

    payload = request.get_json(silent=True) or {}
    alerts = payload.get("alerts", [])
    jlog("webhook_received", receiver=payload.get("receiver"), status=payload.get("status"), alerts=len(alerts))
    results = [handle_alert(a) for a in alerts]
    return jsonify({"results": results})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
