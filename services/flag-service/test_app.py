"""
Teste de smoke do flag-service. O app.py conecta no Postgres logo no
import (SimpleConnectionPool), então mockamos a conexão antes de importar
para o teste rodar isolado, sem precisar de um Postgres real no CI.
"""
import os
from unittest.mock import MagicMock, patch

os.environ.setdefault("DATABASE_URL", "postgres://user:pass@localhost:5432/db")
os.environ.setdefault("AUTH_SERVICE_URL", "http://localhost:8001")

with patch("psycopg2.pool.SimpleConnectionPool", return_value=MagicMock()):
    import app as flag_app


def test_health_check_returns_ok():
    client = flag_app.app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_flags_endpoint_requires_authorization_header():
    client = flag_app.app.test_client()
    response = client.get("/flags")
    assert response.status_code == 401
