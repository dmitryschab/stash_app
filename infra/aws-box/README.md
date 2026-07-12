# Stash AWS box (Terraform)

One small always-on EC2 instance to host the Stash Data Portability webhook receiver (and general use). Locked-down, free-tier-eligible.

**What it creates:** 1× `t3.micro` Ubuntu 24.04 in `eu-north-1` (Stockholm), 20 GB encrypted gp3 root, a generated ED25519 SSH key, an Elastic IP (stable public address), and a security group — SSH open only to the machine that runs `terraform apply`, HTTP/HTTPS open to the world for the webhook.

**Cost:** ~$0/month for the first 12 months on a new account (t3.micro 750 h/mo + 30 GB EBS + EIP-while-attached are all free tier). After the free year, roughly **$8–10/month** (instance + EBS). `terraform destroy` stops all charges.

## 1. Credentials (yours — I can't handle AWS keys)

Terraform authenticates with an access key, not your browser session. In the AWS console:

1. IAM → Users → **Create user** (e.g. `terraform`), then attach a policy — `AdministratorAccess` is simplest for a personal account (tighten later).
2. Open the user → **Security credentials** → **Create access key** → use case "Command Line Interface (CLI)".
3. Configure the CLI (you type the key — never share it):
   ```sh
   aws configure
   # AWS Access Key ID:     <paste>
   # AWS Secret Access Key: <paste>
   # Default region name:   eu-north-1
   # Default output format:  json
   ```
4. Verify: `aws sts get-caller-identity` should print your account `709097782876`.

> More secure alternative: IAM Identity Center + `aws configure sso` (no long-lived keys). Ask if you want that instead.

## 2. Provision

```sh
cd infra/aws-box
terraform init      # already run
terraform plan      # review what will be created
terraform apply     # type "yes"
```

## 3. Connect

```sh
terraform output ssh_command   # prints the exact ssh line
# e.g. ssh -i ./stash-box-key.pem ubuntu@<elastic-ip>
```

## Tear down

```sh
terraform destroy
```

Notes: state is local (`terraform.tfstate`) — fine for one box; the private key `stash-box-key.pem` and state are gitignored (never commit them).
