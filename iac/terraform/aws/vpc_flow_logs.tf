# ---------------------------------------------------------------------------
# VPC Flow Logs (Módulo C: "Habilitar VPC Flow Logs (AWS)").
#
# Destino S3, NO CloudWatch Logs -- a propósito: un flow log hacia
# CloudWatch Logs necesita un rol IAM propio que asuma
# `vpc-flow-logs.amazonaws.com` (`iam:CreateRole`), bloqueado en un AWS
# Academy Learner Lab (ver variables.tf, sección Learner Lab
# compatibility). El destino S3 usa en cambio una bucket policy (no un rol
# asumido) -- cero permisos IAM nuevos, funciona igual bajo `use_academy_lab_role
# = true`. Trade-off: los logs quedan en S3 como objetos (formato por
# defecto, uno por intervalo de captura) en vez de en un log group
# consultable con CloudWatch Logs Insights -- para este laboratorio se
# analizan con Athena/`aws s3 cp` + grep, documentado en
# docs/runbooks/03-modulo-c-network-security.md.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "flow_logs" {
  bucket        = "${var.project_name}-vpc-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # laboratorio desechable -- terraform destroy debe vaciar el bucket sin pasos manuales

  tags = { Name = "${var.project_name}-vpc-flow-logs", Purpose = "game-day-lab-disposable" }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Política mínima requerida por el servicio de VPC Flow Logs para escribir
# en el bucket -- ver
# https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-s3.html#flow-logs-s3-permissions
data "aws_iam_policy_document" "flow_logs_bucket" {
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow_logs.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_bucket.json
}

resource "aws_flow_log" "vpc" {
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flow_logs.arn
  traffic_type             = "ALL" # ACCEPT y REJECT -- REJECT es la señal de "tráfico anómalo" del Módulo C
  vpc_id                   = aws_vpc.main.id
  max_aggregation_interval = 60 # el más granular soportado, mejor resolución temporal para correlacionar con los experimentos de caos

  destination_options {
    file_format        = "parquet" # consultable directo con Athena sin ETL adicional
    per_hour_partition = true
  }

  tags = { Name = "${var.project_name}-vpc-flow-log" }
}
