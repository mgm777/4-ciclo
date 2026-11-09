#!/usr/bin/env python3
"""Gera gitops/observability/config/dashboards/togglemaster-overview.json.

O dashboard é código: edite este script e rode-o de novo, em vez de editar o
JSON à mão (ou exporte da UI e cole o JSON por cima, se preferir).
"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
SVC = 'job=~"$service"'
HTTP = "http_server_request_duration_seconds"

_id = 0


def nid():
    global _id
    _id += 1
    return _id


def row(title, y):
    return {"type": "row", "title": title, "id": nid(), "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def stat(title, expr, x, y, w=4, unit="none", thresholds=None, decimals=None, desc=""):
    steps = thresholds or [{"color": "green", "value": None}]
    p = {"type": "stat", "title": title, "id": nid(), "datasource": PROM, "description": desc,
         "gridPos": {"h": 4, "w": w, "x": x, "y": y},
         "targets": [{"refId": "A", "datasource": PROM, "expr": expr, "instant": True}],
         "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                                      "color": {"mode": "thresholds"}}, "overrides": []},
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": "background", "graphMode": "area", "textMode": "value"}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    return p


def ts(title, targets, x, y, w=12, h=8, unit="short", desc="", threshold=None, stack=False):
    custom = {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 15, "showPoints": "never",
              "spanNulls": True, "stacking": {"mode": "normal" if stack else "none"}}
    steps = [{"color": "green", "value": None}]
    if threshold is not None:
        steps.append({"color": "red", "value": threshold})
        custom["thresholdsStyle"] = {"mode": "dashed+area"}
    return {"type": "timeseries", "title": title, "id": nid(), "datasource": PROM, "description": desc,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "targets": [{"refId": chr(65 + i), "datasource": PROM, "expr": e, "legendFormat": l}
                        for i, (e, l) in enumerate(targets)],
            "fieldConfig": {"defaults": {"unit": unit, "custom": custom,
                                         "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
            "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


panels = []
y = 0

# ---------------------------------------------------------------- Cluster
panels.append(row("☸️ Saúde do cluster (GKE)", y)); y += 1
panels += [
    stat("Nós prontos", 'sum(kube_node_status_condition{condition="Ready",status="true"})', 0, y,
         thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
    stat("CPU do cluster", '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))', 4, y,
         unit="percentunit", decimals=1,
         thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.9}]),
    stat("Memória do cluster", "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)", 8, y,
         unit="percentunit", decimals=1,
         thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.75}, {"color": "red", "value": 0.9}]),
    stat("Pods ToggleMaster Running", 'sum(kube_pod_status_phase{namespace="togglemaster",phase="Running"})', 12, y,
         thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 5}]),
    stat("Restarts de contêiner (1h)",
         'sum(increase(kube_pod_container_status_restarts_total{namespace="togglemaster"}[1h])) or vector(0)', 16, y,
         decimals=0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]),
    stat("Self-healing executados (24h)",
         'sum(increase(self_healer_actions_total{result="healed"}[24h])) or vector(0)', 20, y, decimals=0,
         thresholds=[{"color": "blue", "value": None}],
         desc="Rollout restarts concluídos pelo self-healer (Runbook Automation)."),
]
y += 4
panels += [
    ts("CPU por pod (togglemaster)",
       [('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="togglemaster",container!=""}[$__rate_interval]))', "{{pod}}")],
       0, y, w=8, unit="cores"),
    ts("Memória por pod (togglemaster)",
       [('sum by (pod) (container_memory_working_set_bytes{namespace="togglemaster",container!=""})', "{{pod}}")],
       8, y, w=8, unit="bytes"),
    ts("CPU por nó",
       [('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))', "{{instance}}")],
       16, y, w=8, unit="percentunit"),
]
y += 8

# ---------------------------------------------------------------- RED
panels.append(row("🚦 Microsserviços — taxa, erros e latência (OpenTelemetry)", y)); y += 1
rps_by_job = f"sum by (job) (rate({HTTP}_count{{{SVC}}}[$__rate_interval]))"
err_by_job = f'sum by (job) (rate({HTTP}_count{{{SVC},http_response_status_code=~"5.."}}[$__rate_interval]))'
panels += [
    ts("Requisições por segundo", [(rps_by_job, "{{job}}")], 0, y, w=8, unit="reqps",
       desc="http.server.request.duration (count), emitida pelo otelhttp (Go) e pela instrumentação Flask (Python)."),
    ts("Taxa de erro HTTP 5xx", [(f"({err_by_job} / {rps_by_job}) or ({rps_by_job} * 0)", "{{job}}")], 8, y, w=8,
       unit="percentunit", threshold=0.05,
       desc="Mesma expressão do alerta HTTP5xxErrorRateHigh. Linha vermelha = limite de 5%."),
    ts("Latência p95", [(f"histogram_quantile(0.95, sum by (job, le) (rate({HTTP}_bucket{{{SVC}}}[$__rate_interval])))", "{{job}}")],
       16, y, w=8, unit="s"),
]
y += 8
panels += [
    ts("Requisições por status code",
       [(f"sum by (job, http_response_status_code) (rate({HTTP}_count{{{SVC}}}[$__rate_interval]))",
         "{{job}} {{http_response_status_code}}")], 0, y, w=16, unit="reqps", stack=True),
    {"type": "alertlist", "title": "Alertas ativos", "id": nid(), "gridPos": {"h": 8, "w": 8, "x": 16, "y": y},
     "options": {"alertListOptions": {}, "showInstances": True, "groupMode": "default", "maxItems": 20,
                 "sortOrder": 1, "stateFilter": {"firing": True, "pending": True, "normal": False, "error": True},
                 "viewMode": "list", "alertInstanceLabelFilter": "", "folder": None, "dashboardAlerts": False}},
]
y += 8

# ---------------------------------------------------------------- Logs
panels.append(row("📜 Logs em tempo real (Loki)", y)); y += 1
log_sel = '{k8s_namespace_name="togglemaster", service_name=~"$service"}'
panels += [
    {"type": "timeseries", "title": "Volume de logs de erro", "id": nid(), "datasource": LOKI,
     "gridPos": {"h": 6, "w": 24, "x": 0, "y": y},
     "targets": [{"refId": "A", "datasource": LOKI, "legendFormat": "{{service_name}}",
                  "expr": f'sum by (service_name) (count_over_time({log_sel} |~ "(?i)(error|exception|chaos|traceback)" [$__auto]))'}],
     "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "bars", "fillOpacity": 60, "stacking": {"mode": "normal"}}},
                     "overrides": []},
     "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}},
]
y += 6
panels += [
    {"type": "logs", "title": "Logs dos microsserviços (filtro: $search)", "id": nid(), "datasource": LOKI,
     "gridPos": {"h": 14, "w": 24, "x": 0, "y": y},
     "targets": [{"refId": "A", "datasource": LOKI, "expr": f'{log_sel} |~ "(?i)$search"'}],
     "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True,
                 "prettifyLogMessage": False, "dedupStrategy": "none", "showLabels": False}},
]

dashboard = {
    "uid": "togglemaster-overview",
    "title": "ToggleMaster — Saúde do Ecossistema",
    "tags": ["togglemaster", "opentelemetry", "fase4"],
    "timezone": "browser",
    "editable": True,
    "refresh": "10s",
    "schemaVersion": 39,
    "time": {"from": "now-30m", "to": "now"},
    "templating": {"list": [
        {"name": "service", "label": "Serviço", "type": "query", "datasource": PROM,
         "query": {"query": f"label_values({HTTP}_count, job)", "refId": "service"},
         "definition": f"label_values({HTTP}_count, job)",
         "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*",
         "current": {"text": ["All"], "value": ["$__all"]}},
        {"name": "search", "label": "Busca nos logs (regex)", "type": "textbox", "query": "",
         "current": {"text": "", "value": ""}},
    ]},
    "panels": panels,
}

out = pathlib.Path(__file__).resolve().parent.parent / "gitops/observability/config/dashboards/togglemaster-overview.json"
out.write_text(json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n")
print(f"OK: {out} ({len(panels)} painéis)")
