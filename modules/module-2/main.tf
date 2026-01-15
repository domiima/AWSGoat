terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Suffix unico per evitare collisioni di nomi (AlreadyExists)
resource "random_id" "suffix" {
  byte_length = 4 # 8 chars hex
}

locals {
  suffix = random_id.suffix.hex

  # Prefissi brevi per rispettare limiti di lunghezza (ALB/TG max 32)
  alb_name = "aws-goat-m2-alb-${local.suffix}"
  tg_name  = "aws-goat-m2-tg-${local.suffix}"

  # Nomi univoci per risorse "global-ish" o name-unique
  vpc_name_tag           = "AWS_GOAT_VPC-${local.suffix}"
  db_subnet_group_name   = "database-subnets-${local.suffix}"
  db_identifier          = "aws-goat-db-${local.suffix}"
  secret_name            = "RDS_CREDS-${local.suffix}"

  ecs_cluster_name       = "ecs-lab-cluster-${local.suffix}"
  ecs_service_name       = "ecs_service_worker_${local.suffix}"
  task_family            = "ECS-Lab-Task-definition-${local.suffix}"

  ecs_instance_role_name = "ecs-instance-role-${local.suffix}"
  ecs_task_role_name     = "ecs-task-role-${local.suffix}"
  ec2_deployer_role_name = "ec2Deployer-role-${local.suffix}"

  ecs_instance_profile_name = "ecs-instance-profile-${local.suffix}"
  ec2_deployer_profile_name = "ec2Deployer-${local.suffix}"

  policy_instance_name   = "aws-goat-instance-policy-${local.suffix}"
  policy_boundary_name   = "aws-goat-instance-boundary-policy-${local.suffix}"
  policy_ec2_admin_name  = "ec2DeployerAdmin-policy-${local.suffix}"

  sg_ecs_name            = "ECS-SG-${local.suffix}"
  sg_lb_name             = "Load-Balancer-SG-${local.suffix}"
  sg_db_name             = "Database-SG-${local.suffix}"
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# VPC Config for public access
resource "aws_vpc" "lab-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = local.vpc_name_tag
  }
}

resource "aws_subnet" "lab-subnet-public-1" {
  vpc_id                  = aws_vpc.lab-vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "lab-subnet-public-1b" {
  vpc_id                  = aws_vpc.lab-vpc.id
  cidr_block              = "10.0.128.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "my_vpc_igw" {
  vpc_id = aws_vpc.lab-vpc.id
  tags = {
    Name = "My VPC - Internet Gateway"
  }
}

resource "aws_route_table" "my_vpc_us_east_1_public_rt" {
  vpc_id = aws_vpc.lab-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_vpc_igw.id
  }

  tags = {
    Name = "Public Subnet Route Table."
  }
}

resource "aws_route_table_association" "my_vpc_us_east_1a_public" {
  subnet_id      = aws_subnet.lab-subnet-public-1.id
  route_table_id = aws_route_table.my_vpc_us_east_1_public_rt.id
}

resource "aws_route_table_association" "my_vpc_us_east_1b_public" {
  subnet_id      = aws_subnet.lab-subnet-public-1b.id
  route_table_id = aws_route_table.my_vpc_us_east_1_public_rt.id
}

resource "aws_security_group" "load_balancer_security_group" {
  name        = local.sg_lb_name
  description = "SG for load balancer created from terraform"
  vpc_id      = aws_vpc.lab-vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aws-goat-m2-sg-${local.suffix}"
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = local.sg_ecs_name
  description = "SG for cluster created from terraform"
  vpc_id      = aws_vpc.lab-vpc.id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_security_group.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create Database Subnet Group
resource "aws_db_subnet_group" "database-subnet-group" {
  name        = local.db_subnet_group_name
  subnet_ids  = [aws_subnet.lab-subnet-public-1.id, aws_subnet.lab-subnet-public-1b.id]
  description = "Subnets for Database Instance"

  tags = {
    Name = "Database Subnets ${local.suffix}"
  }
}

# Create Security Group for the Database
resource "aws_security_group" "database-security-group" {
  name        = local.sg_db_name
  description = "Enable MYSQL Aurora access on Port 3306"
  vpc_id      = aws_vpc.lab-vpc.id

  ingress {
    description     = "MYSQL/Aurora Access"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-db-sg-${local.suffix}"
  }
}

# Create Database Instance
resource "aws_db_instance" "database-instance" {
  identifier             = local.db_identifier
  allocated_storage      = 10
  instance_class         = "db.t3.micro"
  engine                 = "mysql"
  engine_version         = "8.0"
  username               = "root"
  password               = "T2kVB3zgeN3YbrKS"
  parameter_group_name   = "default.mysql8.0"
  skip_final_snapshot    = true
  availability_zone      = "us-east-1a"
  db_subnet_group_name   = aws_db_subnet_group.database-subnet-group.name
  vpc_security_group_ids = [aws_security_group.database-security-group.id]
}

# IAM Roles / Policies (all unique)
resource "aws_iam_policy" "ecs_instance_policy" {
  name = local.policy_instance_name
  policy = jsonencode({
    "Statement" : [
      {
        "Action" : [
          "ssm:*",
          "ssmmessages:*",
          "ec2:RunInstances",
          "ec2:Describe*"
        ],
        "Effect" : "Allow",
        "Resource" : "*",
        "Sid" : "Pol1"
      }
    ],
    "Version" : "2012-10-17"
  })
}

resource "aws_iam_policy" "instance_boundary_policy" {
  name = local.policy_boundary_name
  policy = jsonencode({
    "Statement" : [
      {
        "Action" : [
          "iam:List*",
          "iam:Get*",
          "iam:PassRole",
          "iam:PutRole*",
          "ssm:*",
          "ssmmessages:*",
          "ec2:RunInstances",
          "ec2:Describe*",
          "ecs:*",
          "ecr:*",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Effect" : "Allow",
        "Resource" : "*",
        "Sid" : "Pol1"
      }
    ],
    "Version" : "2012-10-17"
  })
}

resource "aws_iam_role" "ecs-instance-role" {
  name                 = local.ecs_instance_role_name
  path                 = "/"
  permissions_boundary = aws_iam_policy.instance_boundary_policy.arn

  assume_role_policy = jsonencode({
    "Version" : "2008-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : { "Service" : "ec2.amazonaws.com" },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs-instance-role-attachment-1" {
  role       = aws_iam_role.ecs-instance-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs-instance-role-attachment-2" {
  role       = aws_iam_role.ecs-instance-role.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

resource "aws_iam_role_policy_attachment" "ecs-instance-role-attachment-3" {
  role       = aws_iam_role.ecs-instance-role.name
  policy_arn = aws_iam_policy.ecs_instance_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecs-instance-role-attachment-ssm" {
  role       = aws_iam_role.ecs-instance-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "ecs-task-role" {
  name = local.ecs_task_role_name
  path = "/"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : { "Service" : "ecs-tasks.amazonaws.com" },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs-task-role-attachment" {
  role       = aws_iam_role.ecs-task-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs-task-role-attachment-2" {
  role       = aws_iam_role.ecs-task-role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_policy" "ec2_deployer_admin_policy" {
  name = local.policy_ec2_admin_name
  policy = jsonencode({
    "Statement" : [
      {
        "Action" : ["*"],
        "Effect" : "Allow",
        "Resource" : "*",
        "Sid" : "Policy1"
      }
    ],
    "Version" : "2012-10-17"
  })
}

resource "aws_iam_role" "ec2-deployer-role" {
  name = local.ec2_deployer_role_name
  path = "/"

  assume_role_policy = jsonencode({
    "Version" : "2008-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : { "Service" : "ec2.amazonaws.com" },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2-deployer-role-attachment" {
  role       = aws_iam_role.ec2-deployer-role.name
  policy_arn = aws_iam_policy.ec2_deployer_admin_policy.arn
}

resource "aws_iam_instance_profile" "ec2-deployer-profile" {
  name = local.ec2_deployer_profile_name
  path = "/"
  role = aws_iam_role.ec2-deployer-role.name
}

resource "aws_iam_instance_profile" "ecs-instance-profile" {
  name = local.ecs_instance_profile_name
  path = "/"
  role = aws_iam_role.ecs-instance-role.name
}

# AMI ECS optimized
data "aws_ami" "ecs_optimized_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-2.0.202*-x86_64-ebs"]
  }
}

resource "aws_launch_template" "ecs_launch_template" {
  name_prefix   = "ecs-launch-template-${local.suffix}-"
  image_id      = data.aws_ami.ecs_optimized_ami.id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs-instance-profile.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_sg.id]
  user_data              = base64encode(data.template_file.user_data.rendered)
}

resource "aws_autoscaling_group" "ecs_asg" {
  name_prefix         = "ECS-lab-asg-${local.suffix}-"
  vpc_zone_identifier = [aws_subnet.lab-subnet-public-1.id]
  desired_capacity    = 1
  min_size            = 0
  max_size            = 1

  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }
}

resource "aws_ecs_cluster" "cluster" {
  name = local.ecs_cluster_name

  tags = {
    name = "ecs-cluster-name-${local.suffix}"
  }
}

data "template_file" "user_data" {
  template = file("${path.module}/resources/ecs/user_data.tpl")
}

resource "aws_ecs_task_definition" "task_definition" {
  container_definitions    = data.template_file.task_definition_json.rendered
  family                   = local.task_family
  network_mode             = "bridge"
  memory                   = "512"
  cpu                      = "512"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.ecs-task-role.arn

  pid_mode = "host"

  volume {
    name      = "modules"
    host_path = "/lib/modules"
  }
  volume {
    name      = "kernels"
    host_path = "/usr/src/kernels"
  }
}

resource "null_resource" "rds_endpoint" {
  provisioner "local-exec" {
    command = <<EOF
RDS_URL="${aws_db_instance.database-instance.endpoint}"
RDS_URL=$${RDS_URL::-5}
sed -i "s,RDS_ENDPOINT_VALUE,$RDS_URL,g" ${path.module}/resources/ecs/task_definition.json
EOF
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    aws_db_instance.database-instance
  ]
}

data "template_file" "task_definition_json" {
  template = file("${path.module}/resources/ecs/task_definition.json")
  depends_on = [
    null_resource.rds_endpoint
  ]
}

resource "aws_alb" "application_load_balancer" {
  name               = local.alb_name
  internal           = false
  load_balancer_type = "application"
  subnets            = [aws_subnet.lab-subnet-public-1.id, aws_subnet.lab-subnet-public-1b.id]
  security_groups    = [aws_security_group.load_balancer_security_group.id]

  tags = {
    Name = local.alb_name
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = local.tg_name
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.lab-vpc.id

  tags = {
    Name = local.tg_name
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.application_load_balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}

resource "aws_ecs_service" "worker" {
  name                              = local.ecs_service_name
  cluster                           = aws_ecs_cluster.cluster.id
  task_definition                   = aws_ecs_task_definition.task_definition.arn
  desired_count                     = 1
  health_check_grace_period_seconds = 2147483647

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn
    container_name   = "aws-goat-m2"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.listener]
}

resource "aws_secretsmanager_secret" "rds_creds" {
  name                    = local.secret_name
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "secret_version" {
  secret_id     = aws_secretsmanager_secret.rds_creds.id
  secret_string = <<EOF
{
  "username": "root",
  "password": "T2kVB3zgeN3YbrKS"
}
EOF
}

resource "null_resource" "cleanup" {
  provisioner "local-exec" {
    command = <<EOF
RDS_URL="${aws_db_instance.database-instance.endpoint}"
RDS_URL=$${RDS_URL::-5}
sed -i "s,$RDS_URL,RDS_ENDPOINT_VALUE,g" ${path.module}/resources/ecs/task_definition.json
EOF
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    null_resource.rds_endpoint,
    aws_ecs_task_definition.task_definition
  ]
}

/* Creating a S3 Bucket for Terraform state file upload. */
resource "aws_s3_bucket" "bucket_tf_files" {
  bucket        = "do-not-delete-awsgoat-state-files-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = {
    Name        = "Do not delete Bucket"
    Environment = "Dev"
  }
}

output "ad_Target_URL" {
  value = "${aws_alb.application_load_balancer.dns_name}:80/login.php"
}
