#!/usr/bin/env bash
# ==============================================================================
# KnowledgeForge — 100% Free Tier AWS EC2 Deployment Script
# Provisions a t2.micro (Free Tier) instance, configures 2GB Swap,
# and runs Backend + Streamlit UI via Docker Compose for $0.00/month.
# ==============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}====================================================================${NC}"
echo -e "${BLUE}${BOLD}   KnowledgeForge: 100% Free Tier AWS EC2 Deployment (t2.micro)     ${NC}"
echo -e "${BLUE}${BOLD}====================================================================${NC}\n"

# 1. Verify AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed or not in PATH.${NC}"
    echo "Install it via: brew install awscli"
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured.${NC}"
    echo "Please run 'aws configure' first."
    exit 1
fi

CONFIGURED_REGION=$(aws configure get region 2>/dev/null || echo "")
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-${CONFIGURED_REGION:-us-east-1}}}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}✅ AWS CLI connected to Account: ${BOLD}${ACCOUNT_ID}${NC}${GREEN} in Region: ${BOLD}${AWS_REGION}${NC}\n"

# Configuration
KEY_NAME="knowledgeforge-key"
SG_NAME="knowledgeforge-free-sg"
# t2.micro is default free tier; in eu-north-1 and newer regions, t3.micro is the free tier instance
if [ "${AWS_REGION}" = "eu-north-1" ] || [ "${AWS_REGION}" = "ap-east-1" ] || [ "${AWS_REGION}" = "me-south-1" ]; then
    INSTANCE_TYPE="t3.micro"
else
    INSTANCE_TYPE="t2.micro"
fi
TAG_NAME="KnowledgeForge-FreeServer"

# 2. Create SSH Key Pair if needed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
KEY_FILE="${ROOT_DIR}/${KEY_NAME}.pem"

if ! aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_REGION}" &> /dev/null; then
    echo -e "${YELLOW}🔑 Creating SSH Key Pair '${KEY_NAME}'...${NC}"
    aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --query 'KeyMaterial' \
        --output text \
        --region "${AWS_REGION}" > "${KEY_FILE}"
    chmod 400 "${KEY_FILE}"
    echo -e "${GREEN}   Saved private key to ${KEY_FILE}${NC}"
else
    echo -e "${GREEN}✅ Key pair '${KEY_NAME}' exists.${NC}"
fi

# 3. Create Security Group if needed
SG_ID=$(aws ec2 describe-security-groups --group-names "${SG_NAME}" --region "${AWS_REGION}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")

if [ -z "${SG_ID}" ] || [ "${SG_ID}" == "None" ]; then
    echo -e "${YELLOW}🛡️ Creating Security Group '${SG_NAME}'...${NC}"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "Security group for KnowledgeForge free server" \
        --region "${AWS_REGION}" \
        --query 'GroupId' \
        --output text)

    # Allow Port 22 (SSH), Port 8501 (Streamlit UI), Port 8080 (FastAPI API)
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 8501 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
    echo -e "${GREEN}   Security Group created: ${SG_ID}${NC}"
else
    echo -e "${GREEN}✅ Security Group '${SG_NAME}' exists: ${SG_ID}${NC}"
fi

# 4. Find latest Ubuntu 24.04 LTS AMI (Free Tier eligible)
echo -e "\n${YELLOW}🔍 Finding latest Ubuntu 24.04 LTS Free-Tier AMI...${NC}"
AMI_ID=$(aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --region "${AWS_REGION}" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" == "None" ]; then
    echo "   Querying EC2 image catalog for Ubuntu 24.04..."
    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" \
        --output text \
        --region "${AWS_REGION}" 2>/dev/null || echo "")
fi

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" == "None" ]; then
    # Fallback to standard Ubuntu 24.04 AMI for eu-north-1 if both queries are restricted
    if [ "${AWS_REGION}" = "eu-north-1" ]; then
        AMI_ID="ami-0705384c0b33c194c"
    else
        AMI_ID="ami-04b4f1a9cf54c11d0"
    fi
fi

echo -e "${GREEN}✅ Selected Free-Tier AMI: ${AMI_ID}${NC}"

# 5. Prepare User Data Startup Script (Installs Docker, creates 2GB swap to prevent OOM)
USER_DATA_FILE=$(mktemp)
cat << 'EOF' > "${USER_DATA_FILE}"
#!/bin/bash
set -e

# 1. Configure 2GB Swap (Essential for t2.micro with 1GB RAM)
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. Install Docker & Docker Compose plugin
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Signal completion
echo "DOCKER_READY" > /tmp/setup_status
EOF

# 6. Launch EC2 Free-Tier Instance
echo -e "\n${YELLOW}🚀 Launching Free-Tier EC2 instance (${INSTANCE_TYPE})...${NC}"

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --count 1 \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --user-data "file://${USER_DATA_FILE}" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
    --region "${AWS_REGION}" \
    --query 'Instances[0].InstanceId' \
    --output text)

rm -f "${USER_DATA_FILE}"

echo -e "${GREEN}✅ Instance launched: ${BOLD}${INSTANCE_ID}${NC}"
echo -e "   Waiting for instance to receive public IP and enter 'running' state..."

aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo -e "${GREEN}✅ Instance is running! Public IP: ${BOLD}${PUBLIC_IP}${NC}"

echo -e "\n${YELLOW}⏳ Waiting ~45 seconds for system packages and Docker to initialize on the server...${NC}"
sleep 45

# 7. Upload project files & .env to EC2
echo -e "\n${YELLOW}📦 Uploading application code to EC2...${NC}"

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}" "mkdir -p ~/KnowledgeForge"

# Sync application files (excluding large unnecessary folders)
rsync -avz -e "ssh -o StrictHostKeyChecking=no -i ${KEY_FILE}" \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '.git' \
    --exclude 'DATA' \
    --exclude 'evals' \
    --exclude 'notebooks' \
    "${ROOT_DIR}/" "ubuntu@${PUBLIC_IP}:~/KnowledgeForge/"

# 8. Start containers with Docker Compose on EC2
echo -e "\n${YELLOW}🐳 Starting containers on EC2 server via Docker Compose...${NC}"

ssh -o StrictHostKeyChecking=no -i "${KEY_FILE}" "ubuntu@${PUBLIC_IP}" "cd ~/KnowledgeForge && docker compose up -d --build"

echo -e "\n${BLUE}${BOLD}====================================================================${NC}"
echo -e "${GREEN}${BOLD}🎉 DEPLOYED SUCCESSFULLY ON 100% FREE AWS EC2 SERVER!${NC}"
echo -e "${BLUE}${BOLD}====================================================================${NC}"
echo -e "Streamlit Chat UI:  ${BOLD}http://${PUBLIC_IP}:8501${NC}"
echo -e "FastAPI Backend API: ${BOLD}http://${PUBLIC_IP}:8080${NC} (Health check: http://${PUBLIC_IP}:8080/health)"
echo -e "SSH Command:         ${BOLD}ssh -i ${KEY_FILE} ubuntu@${PUBLIC_IP}${NC}"
echo -e "Monthly Cost:        ${GREEN}${BOLD}$0.00 / month (AWS Free Tier - 750 hrs/month free)${NC}"
echo -e "${BLUE}${BOLD}====================================================================${NC}\n"
