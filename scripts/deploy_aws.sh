#!/usr/bin/env bash
# ==============================================================================
# KnowledgeForge — AWS App Runner Automated Deployment Script
# Deploys both FastAPI Backend & Streamlit Chat UI to AWS App Runner
# ==============================================================================

set -euo pipefail

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}   KnowledgeForge: Deploying to AWS App Runner (Backend + UI)   ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}\n"

# 1. Check prerequisites
echo -e "${YELLOW}🔍 Step 1: Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker is not installed or not in PATH.${NC}"
    echo "Please install Docker Desktop and start it before running this script."
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker daemon is not running.${NC}"
    echo "Please launch Docker Desktop and try again."
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed.${NC}"
    echo "Install it via Homebrew: brew install awscli"
    echo "Or download from: https://aws.amazon.com/cli/"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}❌ AWS credentials not configured or expired.${NC}"
    echo "Run 'aws configure' to set up your AWS Access Key, Secret Key, and Region."
    exit 1
fi

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}✅ Docker is active.${NC}"
echo -e "${GREEN}✅ AWS CLI configured for Account: ${BOLD}${ACCOUNT_ID}${NC}${GREEN} in Region: ${BOLD}${AWS_REGION}${NC}\n"

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_REPO="knowledgeforge-backend"
UI_REPO="knowledgeforge-ui"
BACKEND_IMAGE="${ECR_REGISTRY}/${BACKEND_REPO}:latest"
UI_IMAGE="${ECR_REGISTRY}/${UI_REPO}:latest"

# 2. Authenticate Docker with Amazon ECR
echo -e "${YELLOW}🔑 Step 2: Authenticating with Amazon ECR...${NC}"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# 3. Create ECR repositories if they don't exist
echo -e "\n${YELLOW}📦 Step 3: Ensuring ECR repositories exist...${NC}"

for REPO in "${BACKEND_REPO}" "${UI_REPO}"; do
    if aws ecr describe-repositories --repository-names "${REPO}" --region "${AWS_REGION}" &> /dev/null; then
        echo -e "${GREEN}   Repository '${REPO}' already exists.${NC}"
    else
        echo -e "   Creating repository '${REPO}'..."
        aws ecr create-repository \
            --repository-name "${REPO}" \
            --region "${AWS_REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 > /dev/null
        echo -e "${GREEN}   Repository '${REPO}' created.${NC}"
    fi
done

# 4. Build and Push Docker images
# CRITICAL: We target linux/amd64 because AWS App Runner compute runs on x86_64/amd64.
echo -e "\n${YELLOW}🔨 Step 4: Building & pushing Docker images (linux/amd64)...${NC}"

echo -e "${BLUE}   Building & pushing Backend (${BACKEND_IMAGE})...${NC}"
docker buildx build \
    --platform linux/amd64 \
    -t "${BACKEND_IMAGE}" \
    -f Dockerfile.backend \
    . \
    --push

echo -e "${GREEN}✅ Backend image pushed successfully.${NC}"

echo -e "${BLUE}   Building & pushing UI (${UI_IMAGE})...${NC}"
docker buildx build \
    --platform linux/amd64 \
    -t "${UI_IMAGE}" \
    -f Dockerfile.ui \
    . \
    --push

echo -e "${GREEN}✅ UI image pushed successfully.${NC}"

# 5. Create or verify App Runner ECR Access IAM Role
echo -e "\n${YELLOW}🛡️ Step 5: Setting up App Runner IAM Access Role...${NC}"
ROLE_NAME="AppRunnerECRAccessRole"

if ! aws iam get-role --role-name "${ROLE_NAME}" &> /dev/null; then
    echo "   Creating IAM role '${ROLE_NAME}'..."
    TRUST_POLICY='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "build.apprunner.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }'
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" > /dev/null

    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
    echo -e "${GREEN}   IAM role '${ROLE_NAME}' created and policy attached.${NC}"
    sleep 10 # Allow IAM role to propagate
else
    echo -e "${GREEN}   IAM role '${ROLE_NAME}' already exists.${NC}"
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# 6. Read Environment Variables from .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ROOT_DIR}/.env"

echo -e "\n${YELLOW}⚙️ Step 6: Preparing service configuration...${NC}"

get_env() {
    local key="$1"
    if [ -f "${ENV_FILE}" ]; then
        grep -E "^${key}=" "${ENV_FILE}" | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' || echo ""
    else
        echo ""
    fi
}

GROQ_API_KEY=$(get_env "GROQ_API_KEY")
GROQ_FALLBACK_API_KEY=$(get_env "GROQ_FALLBACK_API_KEY")
PORTKEY_API_KEY=$(get_env "PORTKEY_API_KEY")
QDRANT_API_KEY=$(get_env "QDRANT_API_KEY")
QDRANT_CLUSTER_ENDPOINT=$(get_env "QDRANT_CLUSTER_ENDPOINT")
LOGFIRE_TOKEN=$(get_env "LOGFIRE_TOKEN")
LANGSMITH_TRACING=$(get_env "LANGSMITH_TRACING")
[ -z "$LANGSMITH_TRACING" ] && LANGSMITH_TRACING="true"
LANGSMITH_API_KEY=$(get_env "LANGSMITH_API_KEY")
LANGSMITH_PROJECT=$(get_env "LANGSMITH_PROJECT")
[ -z "$LANGSMITH_PROJECT" ] && LANGSMITH_PROJECT="rag_scale_test"
LANGSMITH_ENDPOINT=$(get_env "LANGSMITH_ENDPOINT")
[ -z "$LANGSMITH_ENDPOINT" ] && LANGSMITH_ENDPOINT="https://api.smith.langchain.com"
GEMINI_API_KEY=$(get_env "GEMINI_API_KEY")

# 7. Deploy Backend App Runner Service
BACKEND_SERVICE_NAME="knowledgeforge-backend"
echo -e "\n${YELLOW}🚀 Step 7: Deploying Backend Service to App Runner...${NC}"

BACKEND_SERVICE_ARN=$(aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${BACKEND_SERVICE_NAME}'].ServiceArn" --output text)

BACKEND_CONFIG_JSON=$(cat <<EOF
{
    "ServiceName": "${BACKEND_SERVICE_NAME}",
    "SourceConfiguration": {
        "ImageRepository": {
            "ImageIdentifier": "${BACKEND_IMAGE}",
            "ImageRepositoryType": "ECR",
            "ImageConfiguration": {
                "Port": "8080",
                "RuntimeEnvironmentVariables": {
                    "PORT": "8080",
                    "GROQ_API_KEY": "${GROQ_API_KEY}",
                    "GROQ_FALLBACK_API_KEY": "${GROQ_FALLBACK_API_KEY}",
                    "PORTKEY_API_KEY": "${PORTKEY_API_KEY}",
                    "QDRANT_API_KEY": "${QDRANT_API_KEY}",
                    "QDRANT_CLUSTER_ENDPOINT": "${QDRANT_CLUSTER_ENDPOINT}",
                    "LOGFIRE_TOKEN": "${LOGFIRE_TOKEN}",
                    "LANGSMITH_TRACING": "${LANGSMITH_TRACING}",
                    "LANGSMITH_API_KEY": "${LANGSMITH_API_KEY}",
                    "LANGSMITH_PROJECT": "${LANGSMITH_PROJECT}",
                    "LANGSMITH_ENDPOINT": "${LANGSMITH_ENDPOINT}",
                    "GEMINI_API_KEY": "${GEMINI_API_KEY}"
                }
            }
        },
        "AuthenticationConfiguration": {
            "AccessRoleArn": "${ROLE_ARN}"
        },
        "AutoDeploymentsEnabled": true
    },
    "HealthCheckConfiguration": {
        "Protocol": "HTTP",
        "Path": "/health",
        "Interval": 10,
        "Timeout": 5,
        "HealthyThreshold": 1,
        "UnhealthyThreshold": 5
    },
    "InstanceConfiguration": {
        "Cpu": "1 vCPU",
        "Memory": "2 GB"
    }
}
EOF
)

if [ -z "${BACKEND_SERVICE_ARN}" ]; then
    echo "   Creating new Backend service '${BACKEND_SERVICE_NAME}'..."
    BACKEND_SERVICE_ARN=$(aws apprunner create-service \
        --cli-input-json "${BACKEND_CONFIG_JSON}" \
        --region "${AWS_REGION}" \
        --query "Service.ServiceArn" \
        --output text)
    echo -e "${GREEN}   Created service ARN: ${BACKEND_SERVICE_ARN}${NC}"
else
    echo "   Updating existing Backend service '${BACKEND_SERVICE_NAME}'..."
    aws apprunner update-service \
        --service-arn "${BACKEND_SERVICE_ARN}" \
        --source-configuration file://<(echo "${BACKEND_CONFIG_JSON}" | jq '.SourceConfiguration') \
        --health-check-configuration file://<(echo "${BACKEND_CONFIG_JSON}" | jq '.HealthCheckConfiguration') \
        --instance-configuration file://<(echo "${BACKEND_CONFIG_JSON}" | jq '.InstanceConfiguration') \
        --region "${AWS_REGION}" > /dev/null
    echo -e "${GREEN}   Updated service.${NC}"
fi

# Wait for backend URL
echo -e "   Waiting for Backend service URL..."
BACKEND_URL=""
for i in {1..30}; do
    BACKEND_URL=$(aws apprunner describe-service --service-arn "${BACKEND_SERVICE_ARN}" --region "${AWS_REGION}" --query "Service.ServiceUrl" --output text 2>/dev/null || echo "")
    if [ -n "${BACKEND_URL}" ] && [ "${BACKEND_URL}" != "None" ]; then
        BACKEND_URL="https://${BACKEND_URL}"
        break
    fi
    sleep 5
done

echo -e "${GREEN}✅ Backend Service Live URL: ${BOLD}${BACKEND_URL}${NC}"

# 8. Deploy UI App Runner Service
UI_SERVICE_NAME="knowledgeforge-ui"
echo -e "\n${YELLOW}🚀 Step 8: Deploying UI Service to App Runner...${NC}"

UI_SERVICE_ARN=$(aws apprunner list-services --region "${AWS_REGION}" --query "ServiceSummaryList[?ServiceName=='${UI_SERVICE_NAME}'].ServiceArn" --output text)

UI_CONFIG_JSON=$(cat <<EOF
{
    "ServiceName": "${UI_SERVICE_NAME}",
    "SourceConfiguration": {
        "ImageRepository": {
            "ImageIdentifier": "${UI_IMAGE}",
            "ImageRepositoryType": "ECR",
            "ImageConfiguration": {
                "Port": "8501",
                "RuntimeEnvironmentVariables": {
                    "PORT": "8501",
                    "BACKEND_URL": "${BACKEND_URL}",
                    "LOGFIRE_TOKEN": "${LOGFIRE_TOKEN}"
                }
            }
        },
        "AuthenticationConfiguration": {
            "AccessRoleArn": "${ROLE_ARN}"
        },
        "AutoDeploymentsEnabled": true
    },
    "HealthCheckConfiguration": {
        "Protocol": "HTTP",
        "Path": "/_stcore/health",
        "Interval": 10,
        "Timeout": 5,
        "HealthyThreshold": 1,
        "UnhealthyThreshold": 5
    },
    "InstanceConfiguration": {
        "Cpu": "1 vCPU",
        "Memory": "2 GB"
    }
}
EOF
)

if [ -z "${UI_SERVICE_ARN}" ]; then
    echo "   Creating new UI service '${UI_SERVICE_NAME}'..."
    UI_SERVICE_ARN=$(aws apprunner create-service \
        --cli-input-json "${UI_CONFIG_JSON}" \
        --region "${AWS_REGION}" \
        --query "Service.ServiceArn" \
        --output text)
    echo -e "${GREEN}   Created service ARN: ${UI_SERVICE_ARN}${NC}"
else
    echo "   Updating existing UI service '${UI_SERVICE_NAME}'..."
    aws apprunner update-service \
        --service-arn "${UI_SERVICE_ARN}" \
        --source-configuration file://<(echo "${UI_CONFIG_JSON}" | jq '.SourceConfiguration') \
        --health-check-configuration file://<(echo "${UI_CONFIG_JSON}" | jq '.HealthCheckConfiguration') \
        --instance-configuration file://<(echo "${UI_CONFIG_JSON}" | jq '.InstanceConfiguration') \
        --region "${AWS_REGION}" > /dev/null
    echo -e "${GREEN}   Updated service.${NC}"
fi

# Wait for UI URL
echo -e "   Waiting for UI service URL..."
UI_URL=""
for i in {1..30}; do
    UI_URL=$(aws apprunner describe-service --service-arn "${UI_SERVICE_ARN}" --region "${AWS_REGION}" --query "Service.ServiceUrl" --output text 2>/dev/null || echo "")
    if [ -n "${UI_URL}" ] && [ "${UI_URL}" != "None" ]; then
        UI_URL="https://${UI_URL}"
        break
    fi
    sleep 5
done

echo -e "\n${BLUE}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}🎉 DEPLOYMENT INITIATED TO AWS APP RUNNER!${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "Backend API URL:   ${BOLD}${BACKEND_URL}${NC} (Health check: ${BACKEND_URL}/health)"
echo -e "Streamlit Chat UI: ${BOLD}${UI_URL}${NC}"
echo -e "\nApp Runner takes ~3-5 minutes to complete container provisioning."
echo -e "You can monitor the deployment status in the AWS Console or with:"
echo -e "  aws apprunner describe-service --service-arn ${BACKEND_SERVICE_ARN} --query Service.Status"
echo -e "  aws apprunner describe-service --service-arn ${UI_SERVICE_ARN} --query Service.Status"
echo -e "${BLUE}${BOLD}================================================================${NC}\n"
