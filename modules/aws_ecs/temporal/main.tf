module "temporal_aurora_rds" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "8.0.2"

  name              = "${var.deployment_name}-temporal-rds-instance"
  engine            = "aurora-postgresql"
  engine_mode       = "provisioned"
  engine_version    = "14.9"
  storage_encrypted = true

  vpc_id = var.vpc_id

  monitoring_interval = 60

  # Create DB Subnet group using var.subnet_ids
  create_db_subnet_group = true
  subnets                = var.subnet_ids

  master_username             = aws_secretsmanager_secret_version.temporal_aurora_username.secret_string
  master_password             = aws_secretsmanager_secret_version.temporal_aurora_password.secret_string
  manage_master_user_password = false

  apply_immediately   = true
  skip_final_snapshot = true

  serverlessv2_scaling_configuration = {
    min_capacity = 0.5
    max_capacity = 10
  }

  security_group_rules = {
    temporal_ingress = {
      source_security_group_id = var.container_sg_id
    }
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }
}

resource "aws_service_discovery_service" "temporal_frontend_service" {
  name = "temporal"

  dns_config {
    namespace_id = var.private_dns_namespace_id

    dns_records {
      ttl  = 60
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "retool_temporal_frontend" {
  name            = "${var.deployment_name}-frontend"
  cluster         = var.aws_ecs_cluster_id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_temporal_frontend.arn

  # Need to explictly set this in aws_ecs_service to avoid destructive behavior: https://github.com/hashicorp/terraform-provider-aws/issues/22823
  capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = var.launch_type == "FARGATE" ? "FARGATE" : var.aws_ecs_capacity_provider_name
  }

  dynamic "service_registries" {
    for_each = toset([1])
    content {
      registry_arn = aws_service_discovery_service.temporal_frontend_service.arn
    }
  }

  dynamic "network_configuration" {
    for_each = var.launch_type == "FARGATE" ? toset([1]) : toset([])

    content {
      subnets = var.subnet_ids
      security_groups = [
        var.container_sg_id
      ]
      assign_public_ip = true
    }
  }
}

resource "aws_ecs_service" "retool_temporal_history" {
  name            = "${var.deployment_name}-history"
  cluster         = var.aws_ecs_cluster_id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_temporal_history.arn

  # Need to explictly set this in aws_ecs_service to avoid destructive behavior: https://github.com/hashicorp/terraform-provider-aws/issues/22823
  capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = var.launch_type == "FARGATE" ? "FARGATE" : var.aws_ecs_capacity_provider_name
  }

  dynamic "service_registries" {
    for_each = toset([])
    content {
      registry_arn = aws_service_discovery_service.temporal_frontend_service.arn
    }
  }

  dynamic "network_configuration" {
    for_each = var.launch_type == "FARGATE" ? toset([1]) : toset([])

    content {
      subnets = var.subnet_ids
      security_groups = [
        var.container_sg_id
      ]
      assign_public_ip = true
    }
  }
}

resource "aws_ecs_service" "retool_temporal_matching" {
  name            = "${var.deployment_name}-matching"
  cluster         = var.aws_ecs_cluster_id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_temporal_matching.arn

  # Need to explictly set this in aws_ecs_service to avoid destructive behavior: https://github.com/hashicorp/terraform-provider-aws/issues/22823
  capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = var.launch_type == "FARGATE" ? "FARGATE" : var.aws_ecs_capacity_provider_name
  }

  dynamic "service_registries" {
    for_each = toset([])
    content {
      registry_arn = aws_service_discovery_service.temporal_frontend_service.arn
    }
  }

  dynamic "network_configuration" {
    for_each = var.launch_type == "FARGATE" ? toset([1]) : toset([])

    content {
      subnets = var.subnet_ids
      security_groups = [
        var.container_sg_id
      ]
      assign_public_ip = true
    }
  }
}

resource "aws_ecs_service" "retool_temporal_worker" {
  name            = "${var.deployment_name}-worker"
  cluster         = var.aws_ecs_cluster_id
  desired_count   = 1
  task_definition = aws_ecs_task_definition.retool_temporal_worker.arn

  # Need to explictly set this in aws_ecs_service to avoid destructive behavior: https://github.com/hashicorp/terraform-provider-aws/issues/22823
  capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = var.launch_type == "FARGATE" ? "FARGATE" : var.aws_ecs_capacity_provider_name
  }

  dynamic "service_registries" {
    for_each = toset([])
    content {
      registry_arn = aws_service_discovery_service.temporal_frontend_service.arn
    }
  }

  dynamic "network_configuration" {
    for_each = var.launch_type == "FARGATE" ? toset([1]) : toset([])

    content {
      subnets = var.subnet_ids
      security_groups = [
        var.container_sg_id
      ]
      assign_public_ip = true
    }
  }
}

resource "aws_ecs_task_definition" "retool_temporal_frontend" {
  family                   = "${var.deployment_name}-frontend"
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = var.launch_type == "FARGATE" ? aws_iam_role.execution_role[0].arn : null
  requires_compatibilities = var.launch_type == "FARGATE" ? ["FARGATE"] : null
  network_mode             = var.launch_type == "FARGATE" ? "awsvpc" : "bridge"
  cpu                      = var.launch_type == "FARGATE" ? 1024 : null
  memory                   = var.launch_type == "FARGATE" ? 2048 : null
  container_definitions = jsonencode(
    [
      {
        name      = "${var.deployment_name}-frontend"
        essential = true
        image     = var.temporal_image
        cpu       = var.launch_type == "EC2" ? 512 : null
        memory    = var.launch_type == "EC2" ? 1024 : null

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = var.aws_cloudwatch_log_group_id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL_TEMPORAL"
          }
        }

        portMappings = [
          {
            containerPort = 7233
            hostPort      = 7233
            protocol      = "tcp"
          },
          {
            containerPort = 6933
            hostPort      = 6933
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              "name"  = "SERVICES"
              "value" = "frontend"
            },
          ]
        )
      }
    ]
  )
}

resource "aws_ecs_task_definition" "retool_temporal_history" {
  family                   = "${var.deployment_name}-history"
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = var.launch_type == "FARGATE" ? aws_iam_role.execution_role[0].arn : null
  requires_compatibilities = var.launch_type == "FARGATE" ? ["FARGATE"] : null
  network_mode             = var.launch_type == "FARGATE" ? "awsvpc" : "bridge"
  cpu                      = var.launch_type == "FARGATE" ? 2048 : null
  memory                   = var.launch_type == "FARGATE" ? 8192 : null
  container_definitions = jsonencode(
    [
      {
        name      = "${var.deployment_name}-history"
        essential = true
        image     = var.temporal_image
        cpu       = var.launch_type == "EC2" ? 512 : null
        memory    = var.launch_type == "EC2" ? 2048 : null

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = var.aws_cloudwatch_log_group_id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL_TEMPORAL"
          }
        }

        portMappings = [
          {
            containerPort = 7234
            hostPort      = 7234
            protocol      = "tcp"
          },
          {
            containerPort = 6934
            hostPort      = 6934
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              "name"  = "SERVICES"
              "value" = "history"
            },
          ],
          [{
            "name" : "PUBLIC_FRONTEND_ADDRESS",
            "value" : "${var.temporal_cluster_config.host}:${var.temporal_cluster_config.port}"
            }
          ]
        )
      }
    ]
  )
}

resource "aws_ecs_task_definition" "retool_temporal_matching" {
  family                   = "${var.deployment_name}-matching"
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = var.launch_type == "FARGATE" ? aws_iam_role.execution_role[0].arn : null
  requires_compatibilities = var.launch_type == "FARGATE" ? ["FARGATE"] : null
  network_mode             = var.launch_type == "FARGATE" ? "awsvpc" : "bridge"
  cpu                      = var.launch_type == "FARGATE" ? 1024 : null
  memory                   = var.launch_type == "FARGATE" ? 2048 : null
  container_definitions = jsonencode(
    [
      {
        name      = "${var.deployment_name}-matching"
        essential = true
        image     = var.temporal_image
        cpu       = var.launch_type == "EC2" ? 512 : null
        memory    = var.launch_type == "EC2" ? 1024 : null

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = var.aws_cloudwatch_log_group_id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL_TEMPORAL"
          }
        }

        portMappings = [
          {
            containerPort = 7235
            hostPort      = 7235
            protocol      = "tcp"
          },
          {
            containerPort = 6935
            hostPort      = 6935
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              "name"  = "SERVICES"
              "value" = "matching"
            },
          ],
          [{
            "name" : "PUBLIC_FRONTEND_ADDRESS",
            "value" : "${var.temporal_cluster_config.host}:${var.temporal_cluster_config.port}"
            }
          ]
        )
      }
    ]
  )
}

resource "aws_ecs_task_definition" "retool_temporal_worker" {
  family                   = "${var.deployment_name}-worker"
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = var.launch_type == "FARGATE" ? aws_iam_role.execution_role[0].arn : null
  requires_compatibilities = var.launch_type == "FARGATE" ? ["FARGATE"] : null
  network_mode             = var.launch_type == "FARGATE" ? "awsvpc" : "bridge"
  cpu                      = var.launch_type == "FARGATE" ? 512 : null
  memory                   = var.launch_type == "FARGATE" ? 1024 : null
  container_definitions = jsonencode(
    [
      {
        name      = "${var.deployment_name}-worker"
        essential = true
        image     = var.temporal_image
        cpu       = var.launch_type == "EC2" ? 512 : null
        memory    = var.launch_type == "EC2" ? 1024 : null

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = var.aws_cloudwatch_log_group_id
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "SERVICE_RETOOL_TEMPORAL"
          }
        }

        portMappings = [
          {
            containerPort = 7239
            hostPort      = 7239
            protocol      = "tcp"
          },
          {
            containerPort = 6939
            hostPort      = 6939
            protocol      = "tcp"
          }
        ]

        environment = concat(
          local.environment_variables,
          [
            {
              "name"  = "SERVICES"
              "value" = "worker"
            },
          ],
          [{
            "name" : "PUBLIC_FRONTEND_ADDRESS",
            "value" : "${var.temporal_cluster_config.host}:${var.temporal_cluster_config.port}"
            }
          ]
        )
      }
    ]
  )
}
