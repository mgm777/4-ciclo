import os
import sys
import threading
import json
import uuid
import time
import logging
from flask import Flask, jsonify
from dotenv import load_dotenv
from google.cloud import pubsub_v1
from google.cloud import firestore
from google.api_core.exceptions import GoogleAPICallError

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

load_dotenv()

GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID")
PUBSUB_SUBSCRIPTION_ID = os.getenv("PUBSUB_SUBSCRIPTION_ID")
FIRESTORE_COLLECTION = os.getenv("FIRESTORE_COLLECTION")

if not all([GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID, FIRESTORE_COLLECTION]):
    log.critical("Erro: GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID e FIRESTORE_COLLECTION devem ser definidos.")
    sys.exit(1)

try:
    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID)
    firestore_client = firestore.Client(project=GCP_PROJECT_ID)
    log.info(f"Clientes GCP inicializados no projeto {GCP_PROJECT_ID}")
except Exception as e:
    log.critical(f"Erro ao inicializar os clientes GCP: {e}")
    sys.exit(1)


def process_message(received_message):
    message_id = received_message.message.message_id
    try:
        log.info(f"Processando mensagem ID: {message_id}")
        body = json.loads(received_message.message.data.decode("utf-8"))

        event_id = str(uuid.uuid4())

        item = {
            "event_id": event_id,
            "user_id": body["user_id"],
            "flag_name": body["flag_name"],
            "result": body["result"],
            "timestamp": body["timestamp"],
        }

        firestore_client.collection(FIRESTORE_COLLECTION).document(event_id).set(item)

        log.info(f"Evento {event_id} (Flag: {body['flag_name']}) salvo no Firestore.")

        subscriber.acknowledge(request={"subscription": subscription_path, "ack_ids": [received_message.ack_id]})

    except json.JSONDecodeError:
        log.error(f"Erro ao decodificar JSON da mensagem ID: {message_id}")
    except GoogleAPICallError as e:
        log.error(f"Erro do GCP (Firestore ou Pub/Sub) ao processar {message_id}: {e}")
    except Exception as e:
        log.error(f"Erro inesperado ao processar {message_id}: {e}")


def pubsub_worker_loop():
    log.info("Iniciando o worker Pub/Sub...")
    while True:
        try:
            response = subscriber.pull(
                request={"subscription": subscription_path, "max_messages": 10},
                timeout=20,
            )

            if not response.received_messages:
                continue

            log.info(f"Recebidas {len(response.received_messages)} mensagens.")

            for received_message in response.received_messages:
                process_message(received_message)

        except GoogleAPICallError as e:
            log.error(f"Erro do GCP no loop principal do Pub/Sub: {e}")
            time.sleep(10)
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do Pub/Sub: {e}")
            time.sleep(10)


app = Flask(__name__)


@app.route('/health')
def health():
    return jsonify({"status": "ok"})


def start_worker():
    worker_thread = threading.Thread(target=pubsub_worker_loop, daemon=True)
    worker_thread.start()


start_worker()

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8005))
    app.run(host='0.0.0.0', port=port, debug=False)
