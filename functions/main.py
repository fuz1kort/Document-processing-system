import json
import os
import requests
import boto3
import uuid
import ydb
import ydb.iam

# Глобальные переменные для подключения
s3_client = None
driver = None
pool = None
table_name = None

def initialize_clients():
    global s3_client, driver, pool, table_name
    
    if s3_client is None:
        s3_client = boto3.client(
            service_name='s3',
            endpoint_url='https://storage.yandexcloud.net',
            aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
            aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        )

    if driver is None:
        driver = ydb.Driver(
            endpoint=os.getenv('YDB_ENDPOINT'),
            database=os.getenv('YDB_DATABASE'),
            credentials=ydb.iam.MetadataUrlCredentials(),
        )
        driver.wait(fail_fast=True, timeout=10)
        pool = ydb.SessionPool(driver)

    if table_name is None:
        table_name = os.getenv('YDB_TABLE_NAME', 'cw2/documents')

# =======================
# MQ → INSERT
# =======================
def execute_insert(session, object_id, name, url):
    query = f"""
    DECLARE $id AS Utf8;
    DECLARE $name AS Utf8;
    DECLARE $url AS Utf8;

    UPSERT INTO `{table_name}` (id, name, url)
    VALUES ($id, $name, $url);
    """

    session.transaction().execute(
        session.prepare(query),
        {
            "$id": object_id,
            "$name": name,
            "$url": url,
        },
        commit_tx=True,
    )


# =======================
# HTTP → SELECT
# =======================
def execute_select(session):
    query = f"""
    SELECT id, name, url
    FROM `{table_name}`;
    """

    result = session.transaction().execute(
        session.prepare(query),
        commit_tx=True,
    )

    rows = []
    for row in result[0].rows:
        rows.append({
            "id": row.id,
            "name": row.name,
            "url": row.url,
        })

    return rows

# =======================
# HANDLER
# =======================
def handler(event, context):
    initialize_clients()

    # -------- API Gateway --------
    if "httpMethod" in event:
        if event["httpMethod"] == "GET":
            try:
                documents = pool.retry_operation_sync(execute_select)
                return {
                    "statusCode": 200,
                    "headers": {"Content-Type": "application/json"},
                    "body": json.dumps(documents),
                }
            except Exception as e:
                print(f"Ошибка чтения из YDB: {e}")
                return {
                    "statusCode": 500,
                    "body": "Internal Server Error",
                }

        return {"statusCode": 405}

    # -------- Message Queue --------
    for msg in event.get("messages", []):
        body = msg["details"]["message"]["body"]
        data = json.loads(body)

        name = data["name"]
        url = data["url"]

        # 1. Скачать файл
        try:
            resp = requests.get(url)
            resp.raise_for_status()
            file_bytes = resp.content
        except Exception as e:
            print(f"Ошибка скачивания {url}: {e}")
            continue

        # 2. Загрузить в Object Storage
        object_id = str(uuid.uuid4())
        object_key = f"{object_id}_{name}"

        try:
            s3_client.put_object(
                Bucket=os.getenv("BUCKET_NAME"),
                Key=object_key,
                Body=file_bytes
            )
        except Exception as e:
            print(f"Ошибка загрузки в Object Storage: {e}")
            continue

        # 3. Записать в YDB
        try:
            pool.retry_operation_sync(
                lambda session: execute_insert(session, object_id, object_key, url)
            )
        except Exception as e:
            print(f"Ошибка записи в YDB: {e}")
            continue

        print(f"Документ {name} сохранён, ID={object_id}")

    return {"statusCode": 200}