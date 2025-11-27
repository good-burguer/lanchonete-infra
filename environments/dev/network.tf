
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
    Project = "Good-Burger"
    Env     = "dev"
  }
}

# Internet Gateway para subnets públicas
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.gb.id
  tags = {
    Name    = "gb-dev-igw"
    Project = "Good-Burger"
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
    Project = "Good-Burger"
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
    Project = "Good-Burger"
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
    Project = "Good-Burger"
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
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name    = "gb-dev-nat"
    Project = "Good-Burger"
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
    Project = "Good-Burger"
    Env     = "dev"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}