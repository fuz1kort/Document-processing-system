terraform {
  required_version = ">= 0.13"
  required_providers {
    yandex = {
        source = "yandex-cloud/yandex"
    }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

# === Service Accounts ===

resource "yandex_iam_service_account" "api_gw_sa" {
  name = "vvot21-api-gw-sa"
}

resource "yandex_iam_service_account" "mq_trigger_sa" {
  name = "vvot21-mq-trigger-sa"
}

resource "yandex_iam_service_account" "func_processor_sa" {
  name = "vvot21-func-processor-sa"
}

# === Роли для API Gateway ===

resource "yandex_resourcemanager_folder_iam_member" "api_mq_write_role" {
  folder_id = var.folder_id
  role      = "ymq.writer"
  member    = "serviceAccount:${yandex_iam_service_account.api_gw_sa.id}"
}

# resource "yandex_resourcemanager_folder_iam_member" "api_ydb_reader_role" {
#   folder_id = var.folder_id
#   role      = "ydb.viewer"
#   member    = "serviceAccount:${yandex_iam_service_account.api_gw_sa.id}"
# }

resource "yandex_resourcemanager_folder_iam_member" "api_storage_reader_role" {
  folder_id = var.folder_id
  role      = "storage.viewer"
  member    = "serviceAccount:${yandex_iam_service_account.api_gw_sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "api_func_invoker_role" {
  folder_id = var.folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.api_gw_sa.id}"
}

# === Роли для триггера ===

resource "yandex_resourcemanager_folder_iam_member" "trigger_mq_reader_role" {
  folder_id = var.folder_id
  role      = "ymq.reader"
  member    = "serviceAccount:${yandex_iam_service_account.mq_trigger_sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "trigger_func_invoker_role" {
  folder_id = var.folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.mq_trigger_sa.id}"
}

# === Роли для функции ===

resource "yandex_resourcemanager_folder_iam_member" "func_storage_editor_role" {
  folder_id = var.folder_id
  role      = "storage.uploader"
  member    = "serviceAccount:${yandex_iam_service_account.func_processor_sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "func_ydb_editor_role" {
  folder_id = var.folder_id
  role      = "ydb.editor"
  member    = "serviceAccount:${yandex_iam_service_account.func_processor_sa.id}"
}

# === API Gateway ===

resource "yandex_api_gateway" "document_api_gw" {
  name        = "document-api-gateway"
  execution_timeout = "5"
  spec = templatefile("spec.tftpl", 
  {
    bucket_name  = yandex_storage_bucket.bucket.bucket
    api_gw_sa_id = yandex_iam_service_account.api_gw_sa.id
    func_id      = yandex_function.func.id
    folder_id    = var.folder_id
    mq_url       = yandex_message_queue.document_mq.id
    database     = yandex_ydb_database_serverless.metadata_db.database_path
    table_name   = yandex_ydb_table.document_table.path
  })
}

# === Storage Bucket ===

resource "yandex_storage_bucket" "bucket" {
  bucket = "itis-vvot21-document-storage"
  access_key = yandex_iam_service_account_static_access_key.func_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.func_static_key.secret_key
}

# === Function ===

resource "yandex_iam_service_account_static_access_key" "func_static_key" {
  service_account_id = yandex_iam_service_account.func_processor_sa.id
}

resource "yandex_function" "func" {
  name = "itis-vvot21-document-func"
  user_hash = "v1.0"
  runtime = "python312"
  entrypoint = "main.handler"
  memory = "128"
  execution_timeout = "60"
  service_account_id = yandex_iam_service_account.func_processor_sa.id

  environment = {
    BUCKET_NAME       = yandex_storage_bucket.bucket.bucket
    YDB_ENDPOINT      = yandex_ydb_database_serverless.metadata_db.ydb_full_endpoint
    YDB_DATABASE      = yandex_ydb_database_serverless.metadata_db.database_path
    AWS_ACCESS_KEY_ID = yandex_iam_service_account_static_access_key.func_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.func_static_key.secret_key
    YDB_TABLE_NAME    = yandex_ydb_table.document_table.path
  }

  content {
    zip_filename = "../functions/main.zip"
  }
}

# === Message Queue ===

resource "yandex_iam_service_account_static_access_key" "api_gw_static_key" {
  service_account_id = yandex_iam_service_account.api_gw_sa.id
}

resource "yandex_message_queue" "document_mq" {
  name                        = "itis-vvot21-document-mq"
  visibility_timeout_seconds  = 600
  receive_wait_time_seconds   = 20
  message_retention_seconds   = 1209600
  access_key                  = yandex_iam_service_account_static_access_key.api_gw_static_key.access_key
  secret_key                  = yandex_iam_service_account_static_access_key.api_gw_static_key.secret_key
}

# === YDB Database ===

resource "yandex_ydb_database_serverless" "metadata_db" {
  name      = "documents-db"
  serverless_database {
    storage_size_limit = 1
  }
}

resource "yandex_ydb_table" "document_table" {
  path = "cw2/documents"
  connection_string = yandex_ydb_database_serverless.metadata_db.ydb_full_endpoint

  column {
    name = "id"
    type = "Utf8"
  }

  column {
    name = "name"
    type = "Utf8"
  }

  column {
    name = "url"
    type = "Utf8"
  }

  primary_key = ["id"]
}

# === Trigger ===

resource "yandex_function_trigger" "mq_trigger" {
  name        = "document-mq-trigger"
  function {
    id                 = yandex_function.func.id
    service_account_id = yandex_iam_service_account.mq_trigger_sa.id
  }

  message_queue {
    queue_id           = yandex_message_queue.document_mq.arn
    service_account_id = yandex_iam_service_account.mq_trigger_sa.id
    batch_size         = 1
    batch_cutoff       = 10
  }
}