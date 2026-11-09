"""
Teste de smoke do targeting-service. Mesma estratégia do flag-service:
mocka a conexão com o Postgres antes do import para rodar isolado no CI.
"""
import os
from unittest.mock import MagicMock, patch

os.environ.setdefault("DATABASE_URL", "postgres://user:pass@localhost:5432/db")
os.environ.setdefault("AUTH_SERVICE_URL", "http://localhost:8001")

with patch("psycopg2.pool.SimpleConnectionPool", return_value=MagicMock()):
    import app as targeting_app


def test_health_check_returns_ok():
    client = targeting_app.app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_rules_endpoint_requires_authorization_header():
    client = targeting_app.app.test_client()
    response = client.get("/rules/some-flag")
    assert response.status_code == 401
