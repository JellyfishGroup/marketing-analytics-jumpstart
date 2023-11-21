# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  source_root_dir        = "../.."
  dashboard_dataset_name = "maj_dashboard"
  log_dataset_name       = "maj_logs"
  link_load_file         = "load_links.json"

  console        = "https://console.cloud.google.com"
  bq_console     = "${local.console}/bigquery"
  vertex_console = "${local.console}/vertex-ai"

  p_key                     = "project"
  mds_project_url           = "${local.p_key}=${var.mds_project_id}"
  feature_store_project_url = "${local.p_key}=${var.feature_store_project_id}"
  activation_project_url    = "${local.p_key}=${var.activation_project_id}"

  mds_dataform_repo = "marketing-analytics"
}

module "dashboard_bigquery" {
  source  = "terraform-google-modules/bigquery/google"
  version = "~> 5.4"

  dataset_id                 = local.dashboard_dataset_name
  dataset_name               = local.dashboard_dataset_name
  description                = "providing links to looker dashboard"
  project_id                 = var.project_id
  location                   = var.location
  delete_contents_on_destroy = true

  tables = [
    {
      table_id           = "resource_link",
      schema             = file("../../sql/schema/table/resource_link.json"),
      time_partitioning  = null,
      range_partitioning = null,
      expiration_time    = null,
      clustering         = [],
      labels             = {},
  }]
}

module "load_bucket" {
  source        = "terraform-google-modules/cloud-storage/google//modules/simple_bucket"
  version       = "~> 3.4.1"
  project_id    = var.project_id
  name          = "maj-monitor-${var.project_id}"
  location      = var.location
  force_destroy = true
}

data "template_file" "resource_link_content" {
  template = file("${local.source_root_dir}/templates/monitoring_resource_link_template.csv")
  vars = {
    console        = local.console
    bq_console     = local.bq_console
    vertex_console = local.vertex_console

    mds_project           = var.mds_project_id
    feature_store_project = var.feature_store_project_id
    activation_project    = var.activation_project_id

    mds_project_url           = local.mds_project_url
    feature_store_project_url = local.feature_store_project_url
    activation_project_url    = local.activation_project_url

    mds_dataset_suffix     = var.mds_dataset_suffix
    mds_location           = var.mds_location
    mds_dataform_repo      = local.mds_dataform_repo
    mds_dataform_workspace = var.mds_dataform_workspace
  }
}

resource "google_storage_bucket_object" "resource_link_load_file" {
  name    = local.link_load_file
  bucket  = module.load_bucket.name
  content = data.template_file.resource_link_content.rendered
}

resource "google_bigquery_job" "monitor_resources_load" {
  job_id  = uuid()
  project = var.project_id
  load {
    source_uris = [
      "gs://${module.load_bucket.name}/${google_storage_bucket_object.resource_link_load_file.output_name}",
    ]
    destination_table {
      project_id = var.project_id
      dataset_id = module.dashboard_bigquery.bigquery_dataset.dataset_id
      table_id   = module.dashboard_bigquery.table_ids[0]
    }
    write_disposition = "WRITE_TRUNCATE"
  }
  location = var.location
}

module "log_export_bigquery" {
  source  = "terraform-google-modules/bigquery/google"
  version = "~> 5.4"

  dataset_id                 = local.log_dataset_name
  dataset_name               = local.log_dataset_name
  description                = "Holds log exports"
  project_id                 = var.project_id
  location                   = var.location
  delete_contents_on_destroy = true
}

resource "google_logging_project_sink" "mds_daily_execution" {
  name                   = "mds_execution_export"
  project                = var.mds_project_id
  filter                 = "resource.type=\"dataform.googleapis.com/Repository\""
  destination            = "bigquery.googleapis.com/projects/${module.log_export_bigquery.project}/datasets/${module.log_export_bigquery.bigquery_dataset.dataset_id}"
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_project_iam_member" "mds_daily_execution_member" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = element(concat(google_logging_project_sink.mds_daily_execution[*].writer_identity, [""]), 0)
}

resource "google_logging_project_sink" "vertex_pipeline_execution" {
  name                   = "vertex_pipeline_execution_export"
  project                = var.feature_store_project_id
  filter                 = "jsonPayload.@type=\"type.googleapis.com/google.cloud.aiplatform.logging.PipelineJobLogEntry\" AND (jsonPayload.state=\"PIPELINE_STATE_SUCCEEDED\" OR \"PIPELINE_STATE_FAILED\" OR \"PIPELINE_STATE_CANCELLED\")"
  destination            = "bigquery.googleapis.com/projects/${module.log_export_bigquery.project}/datasets/${module.log_export_bigquery.bigquery_dataset.dataset_id}"
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_project_iam_member" "vertex_pipeline_execution_member" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = element(concat(google_logging_project_sink.vertex_pipeline_execution[*].writer_identity, [""]), 0)
}

resource "google_logging_project_sink" "activation_pipeline_execution" {
  name                   = "activation_pipeline_execution_export"
  project                = var.activation_project_id
  filter                 = "resource.labels.job_name=\"activation-processing\" AND textPayload=\"Worker pool stopped.\""
  destination            = "bigquery.googleapis.com/projects/${module.log_export_bigquery.project}/datasets/${module.log_export_bigquery.bigquery_dataset.dataset_id}"
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_project_iam_member" "activation_pipeline_execution_member" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = element(concat(google_logging_project_sink.activation_pipeline_execution[*].writer_identity, [""]), 0)
}
