terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}
provider "aws" { region = var.aws_region }

############################
# VPC mínima (dev)
############################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "gb" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name    = "gb-dev-vpc"
    Project = "Good-Burguer"
    Env     = "dev"
  }
}

# Internet Gateway para subnets públicas
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.gb.id
  tags = {
    Name    = "gb-dev-igw"
    Project = "Good-Burguer"
    Env     = "dev"
  }
}

# 2 subnets públicas (em 2 AZs)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.gb.id
  cidr_block              = ["10.10.0.0/24", "10.10.1.0/24"][count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name    = "gb-dev-public-${count.index + 1}"
    Project = "Good-Burguer"
    Env     = "dev"
    Tier    = "public"
  }
}

# 2 subnets privadas (em 2 AZs)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.gb.id
  cidr_block        = ["10.10.10.0/24", "10.10.11.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name    = "gb-dev-private-${count.index + 1}"
    Project = "Good-Burguer"
    Env     = "dev"
    Tier    = "private"
  }
}

# Route table pública (rota 0.0.0.0/0 para o IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.gb.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name    = "gb-dev-public-rt"
    Project = "Good-Burguer"
    Env     = "dev"
  }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway (em uma subnet pública) + EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name    = "gb-dev-nat-eip"
    Project = "Good-Burguer"
    Env     = "dev"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name    = "gb-dev-nat"
    Project = "Good-Burguer"
    Env     = "dev"
  }
  depends_on = [aws_internet_gateway.igw]
}

# Route table privada (rota 0.0.0.0/0 via NAT)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.gb.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name    = "gb-dev-private-rt"
    Project = "Good-Burguer"
    Env     = "dev"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
# Role do Cluster EKS
data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "gb-dev-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKS_VPCResourceController" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Role dos Nós (Node Group)
data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "gb-dev-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags = {
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}