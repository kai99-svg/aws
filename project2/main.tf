########################################
# PROVIDERS AND VARIABLES
########################################

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# ⚠️ DO NOT hardcode credentials here in production
provider "aws" {
  region     = "us-east-1"
}

# Variable for subnet CIDR prefixes
variable "subnet_prefix" {
  description = "List of CIDR blocks for subnets"
  type        = list(string)
}
# S3 bucket for the tfstate.
terraform {
  backend "s3" {
    bucket         = "kaikai-bucket-2025"  # your bucket name
    key            = "aws/terraform.tfstate"    # path inside bucket for the state file
    region         = "us-east-1"
    dynamodb_table = "your-lock-table"              # your DynamoDB table for locking
    use_lockfile   = true
  }
}
########################################
# NETWORKING - VPC, Subnets, IGW, Routing
########################################

# Create a VPC
resource "aws_vpc" "first_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "Web_vpc"
  }
}

# Create Subnets
resource "aws_subnet" "my_subnet" {
  vpc_id            = aws_vpc.first_vpc.id
  cidr_block        = var.subnet_prefix[0]
  availability_zone = "us-east-1a"
  tags = {
    Name = "Prod_subnet"
  }
}

resource "aws_subnet" "dev_subnet" {
  vpc_id            = aws_vpc.first_vpc.id
  cidr_block        = var.subnet_prefix[1]
  availability_zone = "us-east-1b"
  tags = {
    Name = "Dev_subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.first_vpc.id
  tags = {
    Name = "first_igw"
  }
}

# Route Table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.first_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "prod_route"
  }
}

# Route Table Associations
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.my_subnet.id
  route_table_id = aws_route_table.route_table.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.dev_subnet.id
  route_table_id = aws_route_table.route_table.id
}

########################################
# SECURITY GROUPS
########################################

# Allow HTTP, HTTPS, and SSH access
resource "aws_security_group" "allow_web" {
  name        = "allow_web"
  description = "Allow web inbound traffic"
  vpc_id      = aws_vpc.first_vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
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
    Name = "Allow_web"
  }
}

# Security group for Load Balancer
resource "aws_security_group" "alb" {
  name   = "alb_security_group"
  vpc_id = aws_vpc.first_vpc.id
}

# Ingress rule for ALB
resource "aws_security_group_rule" "allow_alb_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Egress rule for ALB
resource "aws_security_group_rule" "allow_alb_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
########################################
# CREATE KEY
########################################
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "generated_key" {
  key_name   = "key"
  public_key = tls_private_key.example.public_key_openssh
}

########################################
# EC2 INSTANCES AND NETWORK INTERFACES
########################################

# ENIs for web servers
resource "aws_network_interface" "web_server" {
  subnet_id       = aws_subnet.my_subnet.id
  security_groups = [aws_security_group.allow_web.id]
}

resource "aws_network_interface" "web_server2" {
  subnet_id       = aws_subnet.dev_subnet.id
  security_groups = [aws_security_group.allow_web.id]
}

# EC2 Instance 1
resource "aws_instance" "instance1" {
  ami           = "ami-0360c520857e3138f"
  instance_type = "t3.micro"
  availability_zone = "us-east-1a"
  key_name = aws_key_pair.generated_key.key_name

  primary_network_interface {
    network_interface_id = aws_network_interface.web_server.id
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo apt update -y
              sudo apt install apache2 -y
              sudo systemctl start apache2
              sudo bash -c 'echo your first web server1 > /var/www/html/index.html'
              EOF

  tags = {
    Name = "Myphp"
    env  = "Prod"
  }
}

# EC2 Instance 2
resource "aws_instance" "instance2" {
  ami           = "ami-0360c520857e3138f"
  instance_type = "t3.micro"
  availability_zone = "us-east-1b"
  key_name = aws_key_pair.generated_key.key_name

  primary_network_interface {
    network_interface_id = aws_network_interface.web_server2.id
  }

  user_data = <<-EOF
              #!/bin/bash
              sudo apt update -y
              sudo apt install apache2 -y
              sudo systemctl start apache2
              sudo bash -c 'echo your first web server2 > /var/www/html/index.html'
              EOF

  tags = {
    Name = "Myphp"
    env  = "Prod"
  }
}

########################################
# ELASTIC IPs AND ASSOCIATIONS
########################################

resource "aws_eip" "one" {
  network_interface = aws_network_interface.web_server.id
  depends_on        = [aws_instance.instance1]
}

resource "aws_eip" "two" {
  network_interface = aws_network_interface.web_server2.id
  depends_on        = [aws_instance.instance2]
}

resource "aws_eip_association" "prod_assoc" {
  instance_id   = aws_instance.instance1.id
  allocation_id = aws_eip.one.id
}

resource "aws_eip_association" "prod_assoc2" {
  instance_id   = aws_instance.instance2.id
  allocation_id = aws_eip.two.id
}

########################################
# LOAD BALANCER
########################################

resource "aws_lb" "lb" {
  name               = "web"
  load_balancer_type = "application"
  subnets            = [aws_subnet.my_subnet.id, aws_subnet.dev_subnet.id]
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "instances" {
  name     = "example-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.first_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "instances1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "instances2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance2.id
  port             = 80
}

resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_alb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}

########################################
# ROUTE53 DNS RECORD
########################################

resource "aws_route53_zone" "primary" {
  name = "abc1234567.dpdns.org"
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "abc1234567.dpdns.org"
  type    = "A"

  alias {
    name                   = aws_lb.lb.dns_name
    zone_id                = aws_lb.lb.zone_id
    evaluate_target_health = true
  }
}

########################################
# OUTPUTS
########################################

output "server_public_ip" {
  value = aws_eip.one.public_ip
}
