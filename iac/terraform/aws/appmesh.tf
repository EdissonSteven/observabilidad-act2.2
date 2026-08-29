# ---------------------------------------------------------------------------
# AWS App Mesh -- service mesh básico (Módulo A: "Implementar service mesh
# básico ... para observabilidad de red L7").
#
# `enable_app_mesh = false` por defecto A PROPÓSITO: es la pieza de mayor
# riesgo de todo este módulo (sidecar Envoy + `proxyConfiguration` de ECS +
# el rol de tarea necesita la política administrada
# `AWSAppMeshEnvoyAccess`, que bajo `use_academy_lab_role = true` depende de
# que el LabRole del Learner Lab ya la traiga adjunta -- confirmarlo con
# scripts/aws_preflight_check.sh: `aws iam list-attached-role-policies
# --role-name LabRole | grep AppMesh`). Actívalo SOLO después de validar el
# resto del stack (service-a/b/data-service, RDS, alarmas) sin mesh, para no
# mezclar dos fuentes de fallo distintas en el mismo `apply`.
#
# La imagen de Envoy de App Mesh es específica por región (tabla oficial:
# https://docs.aws.amazon.com/app-mesh/latest/userguide/envoy.html) -- el
# default de `envoy_image_account_id` (840364872350) corresponde a
# us-east-1, el default de `aws_region` en este módulo. Si cambias de
# región, actualiza ese ID o el `apply` fallará al no encontrar la imagen.
# ---------------------------------------------------------------------------

resource "aws_appmesh_mesh" "main" {
  count = var.enable_app_mesh ? 1 : 0
  name  = "${var.project_name}-mesh"

  spec {
    egress_filter {
      type = "ALLOW_ALL" # laboratorio: sin restricción de egress adicional al mesh
    }
  }
}

locals {
  envoy_image = "${var.envoy_image_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/aws-appmesh-envoy:${var.envoy_image_tag}"

  # Contenedor Envoy reutilizable, parametrizado por el ARN del virtual node
  # correspondiente -- se añade a cada task definition vía concat() cuando
  # enable_app_mesh = true (ver la edición de proxy_configuration/container
  # list en main.tf y data_service_ecs.tf).
  envoy_container = { for name, node in {
    "service-a"    = var.enable_app_mesh ? aws_appmesh_virtual_node.service_a[0].arn : ""
    "service-b"    = var.enable_app_mesh ? aws_appmesh_virtual_node.service_b[0].arn : ""
    "data-service" = var.enable_app_mesh ? aws_appmesh_virtual_node.data_service[0].arn : ""
    } : name => {
    name      = "envoy"
    image     = local.envoy_image
    essential = true
    user      = "1337"
    portMappings = [
      { containerPort = 9901, protocol = "tcp" }, # admin/stats de Envoy
      { containerPort = 15000, protocol = "tcp" },
      { containerPort = 15001, protocol = "tcp" },
    ]
    environment = [
      { name = "APPMESH_RESOURCE_ARN", value = node },
      { name = "ENABLE_ENVOY_STATS_TAGS", value = "1" },
      { name = "ENVOY_LOG_LEVEL", value = "info" },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "curl -s http://localhost:9901/server_info | grep state | grep -q LIVE"]
      interval    = 5
      timeout     = 2
      retries     = 3
      startPeriod = 10
    }
  } }
}

# --- Virtual nodes (uno por microservicio) ---------------------------------

resource "aws_appmesh_virtual_node" "service_a" {
  count = var.enable_app_mesh ? 1 : 0
  name  = "service-a"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    listener {
      port_mapping {
        port     = 8000
        protocol = "http"
      }
    }
    service_discovery {
      aws_cloud_map {
        namespace_name = aws_service_discovery_private_dns_namespace.internal.name
        service_name   = "service-a"
      }
    }
    backend {
      virtual_service {
        virtual_service_name = aws_appmesh_virtual_service.service_b[0].name
      }
    }
    backend {
      virtual_service {
        virtual_service_name = aws_appmesh_virtual_service.data_service[0].name
      }
    }
  }
}

resource "aws_appmesh_virtual_node" "service_b" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "service-b"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    listener {
      port_mapping {
        port     = 8001
        protocol = "http"
      }
    }
    service_discovery {
      aws_cloud_map {
        namespace_name = aws_service_discovery_private_dns_namespace.internal.name
        service_name   = "service-b"
      }
    }
  }
}

resource "aws_appmesh_virtual_node" "data_service" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "data-service"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    listener {
      port_mapping {
        port     = 8002
        protocol = "http"
      }
    }
    service_discovery {
      aws_cloud_map {
        namespace_name = aws_service_discovery_private_dns_namespace.internal.name
        service_name   = "data-service"
      }
    }
  }
}

# --- Virtual routers + virtual services (service-b y data-service, los dos
#     "backends" que service-a consume a través del mesh) -----------------

resource "aws_appmesh_virtual_router" "service_b" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "service-b-router"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    listener {
      port_mapping {
        port     = 8001
        protocol = "http"
      }
    }
  }
}

resource "aws_appmesh_route" "service_b" {
  count               = var.enable_app_mesh ? 1 : 0
  name                = "service-b-route"
  mesh_name           = aws_appmesh_mesh.main[0].id
  virtual_router_name = aws_appmesh_virtual_router.service_b[0].name

  spec {
    http_route {
      match {
        prefix = "/"
      }
      action {
        weighted_target {
          virtual_node = aws_appmesh_virtual_node.service_b[0].name
          weight       = 100
        }
      }
    }
  }
}

resource "aws_appmesh_virtual_service" "service_b" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "service-b.${var.project_name}.local"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    provider {
      virtual_router {
        virtual_router_name = aws_appmesh_virtual_router.service_b[0].name
      }
    }
  }
}

resource "aws_appmesh_virtual_router" "data_service" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "data-service-router"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    listener {
      port_mapping {
        port     = 8002
        protocol = "http"
      }
    }
  }
}

resource "aws_appmesh_route" "data_service" {
  count               = var.enable_app_mesh ? 1 : 0
  name                = "data-service-route"
  mesh_name           = aws_appmesh_mesh.main[0].id
  virtual_router_name = aws_appmesh_virtual_router.data_service[0].name

  spec {
    http_route {
      match {
        prefix = "/"
      }
      action {
        weighted_target {
          virtual_node = aws_appmesh_virtual_node.data_service[0].name
          weight       = 100
        }
      }
    }
  }
}

resource "aws_appmesh_virtual_service" "data_service" {
  count     = var.enable_app_mesh ? 1 : 0
  name      = "data-service.${var.project_name}.local"
  mesh_name = aws_appmesh_mesh.main[0].id

  spec {
    provider {
      virtual_router {
        virtual_router_name = aws_appmesh_virtual_router.data_service[0].name
      }
    }
  }
}
