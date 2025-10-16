# Discover existing default VPC internet gateway
data "aws_internet_gateway" "default_igw" {
  filter {
    name = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Materialize details
data "aws_subnet" "default_details" {
  for_each = toset(data.aws_subnets.default.ids)
  id = each.value
}

locals {
  public_default_subnets_all = [
    for s in data.aws_subnet.default_details : s
    if s.map_public_ip_on_launch == true
  ]

  # Group public subnets by AZ ID
  public_by_azid = {
    for s in local.public_default_subnets_all :
    s.availability_zone_id => s.id...
  }

  # One public subnet per AZ
  public_one_per_az = {
    for azid, ids in local.public_by_azid :
    azid => sort(ids)[0]
  }

  # Final distinct list
  public_subnets_distinct = values(local.public_one_per_az)
  public_subnets_two = slice(
    local.public_subnets_distinct,
    0,
    min(2, length(local.public_subnets_distinct))
  )
}


# NAT in the first selected public subnet
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = { Name = "a2-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id = local.public_subnets_two[0]
  tags = { Name = "a2-nat-gw" }
  depends_on = [data.aws_internet_gateway.default_igw]
}

# Read the AZs of the chosen public subnets
data "aws_subnet" "pub_sel" {
  for_each = toset(local.public_subnets_two)
  id = each.value
}

locals {
  public_azs = [for s in data.aws_subnet.pub_sel : s.availability_zone]
}

# Create private subnets in matching AZs
resource "aws_subnet" "private" {
  count = length(local.public_subnets_two)
  vpc_id = data.aws_vpc.default.id
  cidr_block = var.private_subnet_cidrs[count.index]
  availability_zone = local.public_azs[count.index]
  map_public_ip_on_launch = false
  timeouts {
    delete = "15m"
  }

  tags = { Name = "a2-private-${count.index}" }
}

# Route table for the private subnets
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
  tags = { Name = "a2-private-rt" }
}

resource "aws_route" "private_default" {
  route_table_id = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat.id
}

# Associate private subnets with that route table
resource "aws_route_table_association" "private_assoc" {
  count = length(aws_subnet.private)
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
