# 100% Free Tier AWS Deployment Guide (EC2 t2.micro)

This guide walks you through deploying **KnowledgeForge** to **AWS Elastic Compute Cloud (EC2)** completely within the **AWS 12-Month Free Tier** for **$0.00/month**.

---

## 💰 How is this 100% Free on AWS?

AWS provides a generous Free Tier for the first 12 months of your account:
* **750 hours/month of `t2.micro` (or `t3.micro`)**: A standard month has 744 hours (31 days × 24 hrs). 750 hours means you can run one instance **24/7 without paying a single cent**.
* **750 hours/month of in-use Public IPv4**: Covers your instance's public IP address.
* **30 GB of Amazon EBS SSD storage**: We allocate 20 GB gp3, well within the 30 GB free quota.
* **100 GB of free internet egress per month**.

| Resource | AWS Free Tier Quota | KnowledgeForge Usage | Monthly Cost |
| :--- | :--- | :--- | :--- |
| **EC2 Compute** | 750 hours `t2.micro` | 744 hours (1 instance 24/7) | **$0.00** |
| **Public IPv4** | 750 hours in-use IPv4 | 744 hours attached to instance | **$0.00** |
| **EBS Storage** | 30 GB gp3 | 20 GB gp3 | **$0.00** |
| **Total Cost** | — | — | **$0.00 / month** |

> [!IMPORTANT]
> **Why `t2.micro` needs Swap:**
> `t2.micro` has 1 GB of physical RAM. Running both the FastAPI backend and Streamlit UI in Docker requires ~800MB–1.2GB. Our automated setup creates a **2 GB Swap file** on the SSD, giving the server **3 GB of effective memory**. This prevents out-of-memory (OOM) crashes while staying 100% free!

---

## 🚀 Option A: Automated 1-Click Deployment (Recommended)

Run our automated script from your Mac terminal:

```bash
cd /Users/rajvardhansrivastav/Desktop/enterprise_grade/KnowledgeForge
./scripts/deploy_free_ec2.sh
```

### What the script does automatically:
1. Generates an SSH key pair (`knowledgeforge-key.pem`).
2. Configures an EC2 Security Group opening ports `22` (SSH), `8501` (Streamlit Chat UI), and `8080` (FastAPI).
3. Launches an Ubuntu 24.04 `t2.micro` Free-Tier instance.
4. Automatically provisions Docker, Docker Compose, and a 2GB Swap space.
5. Uploads your code and `.env` configuration.
6. Starts both containers via Docker Compose.
7. Outputs your live link: `http://<YOUR_EC2_PUBLIC_IP>:8501`.

---

## 🖥️ Option B: Step-by-Step via AWS Management Console

If you prefer using the AWS Web Console:

### Step 1: Launch the Free-Tier Instance
1. Open the [AWS EC2 Console](https://console.aws.amazon.com/ec2).
2. Click **Launch Instance**.
3. **Name**: `KnowledgeForge-Server`
4. **OS (AMI)**: Select **Ubuntu 24.04 LTS** (verify it shows *"Free tier eligible"*).
5. **Instance type**: Select **`t2.micro`** (1 vCPU, 1 GiB Memory, *"Free tier eligible"*).
6. **Key pair**: Select **Create new key pair** → RSA / `.pem` → Download it as `knowledgeforge-key.pem`.
7. **Network settings**:
   - Check **Allow SSH traffic from Anywhere (0.0.0.0/0)**.
   - Click **Edit** and add two Custom TCP rules:
     - Port **8501** (Streamlit UI) → Source `0.0.0.0/0`
     - Port **8080** (FastAPI Backend) → Source `0.0.0.0/0`
8. **Configure storage**: Set to **20 GiB** `gp3` (under the 30 GiB free limit).
9. Click **Launch instance**.

---

### Step 2: Connect to your Server
In your terminal, navigate to where you saved your `.pem` file:
```bash
chmod 400 knowledgeforge-key.pem
ssh -i knowledgeforge-key.pem ubuntu@<YOUR_EC2_PUBLIC_IP>
```

---

### Step 3: Configure 2GB Swap & Install Docker
Run these commands inside the EC2 instance:
```bash
# 1. Create 2GB swap space (prevents OOM on 1GB RAM)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 2. Install Docker & Docker Compose
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu
newgrp docker
```

---

### Step 4: Clone & Run KnowledgeForge
```bash
git clone <YOUR_GITHUB_REPO_URL> KnowledgeForge
cd KnowledgeForge

# Create your .env file with your API keys
nano .env

# Start both services
docker compose up -d --build
```

---

## 🌐 Accessing Your Application

* **Streamlit Chat UI**: `http://<EC2_PUBLIC_IP>:8501`
* **FastAPI Backend**: `http://<EC2_PUBLIC_IP>:8080/health`
