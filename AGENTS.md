# Multiwoven - igual Fork Documentation

This is igual's fork of Multiwoven with custom initializers and CI/CD for deployment on AWS EKS.

## Project Overview

**Fork of:** [Multiwoven/multiwoven](https://github.com/Multiwoven/multiwoven)  
**Purpose:** Self-hosted data integration platform with igual-specific customizations  
**Deployment:** AWS EKS (sa-east-1) via Helm charts in `igualparatodos/kubernetes` repo

## igual-Specific Customizations

### 1. Custom Rails Initializers

Located in `server/config/initializers/`, these files implement igual's security and operational requirements:

#### `rails_host_authorization.rb` (Modified)
**Purpose:** Disable Rails HostAuthorization middleware to allow ALB health checks

**Why:** AWS ALB sends health check requests with pod IP addresses as the `Host` header. Rails HostAuthorization blocks these, causing 403 errors and marking targets as unhealthy.

**Changes:**
- **Original:** Allowed `.squared.ai`, `.staging.squared.ai`, `localhost`, and `ENV["ALLOWED_HOST"]`
- **Modified:** Completely disables HostAuthorization by clearing `config.hosts` and deleting the middleware

**Implementation:**
```ruby
unless Rails.env.test?
  Rails.application.config.hosts.clear
  Rails.application.config.middleware.delete ActionDispatch::HostAuthorization
end
```

#### `restrict_email_domains.rb` (New)
**Purpose:** Restrict user signups to specific email domains (e.g., `@igual.com`)

**Configuration:** Set `ALLOWED_EMAIL_DOMAINS` environment variable (comma-separated list)

**Features:**
- Uses both ActiveRecord validation and `before_create` callback for enforcement
- Logs blocked signup attempts for security auditing
- Prevents database record creation for disallowed domains

**Implementation:**
```ruby
Rails.application.config.to_prepare do
  User.class_eval do
    validate :email_domain_allowed
    before_create :check_email_domain_before_create
  end
end
```

**Deployment Configuration:**
```yaml
# ConfigMap
ALLOWED_EMAIL_DOMAINS: "igual.com"
```

#### `fix_action_mailer_urls.rb` (New)
**Purpose:** Generate absolute URLs with HTTPS protocol in email verification links

**Why:** Multiwoven's `application.rb` sets `default_url_options` with only `host`, resulting in relative URLs (`/verify-user`) instead of absolute URLs (`https://multiwoven.igual.cloud/verify-user`). This causes browser redirect warnings.

**Implementation:**
```ruby
Rails.application.config.after_initialize do
  Rails.application.config.action_mailer.default_url_options = {
    protocol: "https",
    host: ENV.fetch("SMTP_HOST", "multiwoven.igual.cloud")
  }
end
```

**Deployment Configuration:**
```yaml
# AWS Secrets Manager: production-multiwoven
smtp_host: multiwoven.igual.cloud  # Used for email links
smtp_port: 587                      # STARTTLS (not 465)
smtp_address: email-smtp.sa-east-1.amazonaws.com
```

**Note:** Port 587 is required because Multiwoven uses `enable_starttls_auto: true`. Port 465 (implicit SSL) causes `Net::ReadTimeout` errors.

### 2. GitHub Actions CI/CD

#### Workflow: `build-ecr.yml`
**Purpose:** Build and push custom Multiwoven image to AWS ECR

**Triggers:**
- Push to `main` branch
- Changes in `server/**` directory
- Changes to workflow file itself

**Process:**
1. Checkout code
2. Configure AWS credentials via OIDC (role: `arn:aws:iam::992382838579:role/github`)
3. Login to ECR
4. Create ECR repository if needed (`multiwoven-server`)
5. Build Docker image from `server/Dockerfile`
6. Push with three tags:
   - `latest` - Always points to the most recent build
   - `<git-sha-short>` - Git commit SHA (first 7 chars)
   - `<timestamp>` - Build timestamp (YYYYMMDD-HHMMSS)

**Docker Build:**
- **Context:** Root directory (`.`)
- **Dockerfile:** `server/Dockerfile`
- **Cache:** GitHub Actions cache for faster rebuilds
- **Provenance:** Disabled for compatibility

**Output Example:**
```
992382838579.dkr.ecr.sa-east-1.amazonaws.com/multiwoven-server:latest
992382838579.dkr.ecr.sa-east-1.amazonaws.com/multiwoven-server:2ac1ae5
992382838579.dkr.ecr.sa-east-1.amazonaws.com/multiwoven-server:20251113-203000
```

### 3. Deployment Architecture

**Repository Structure:**
- **This repo:** Application code + custom initializers + CI/CD
- **kubernetes repo:** Helm charts, ConfigMaps, Secrets, Ingress

**Deployment Flow:**
1. Code pushed to `main` → GitHub Actions builds image → Pushes to ECR
2. Update Helm `values.yaml` in kubernetes repo with new image tag
3. ArgoCD auto-syncs or manual sync triggers deployment
4. New pods start with custom initializers baked into the image

**Kubernetes Resources:**
- **Namespace:** `data`
- **Helm Release:** `production-multiwoven`
- **Services:**
  - `production-multiwoven-server` (Rails API, port 3000)
  - `production-multiwoven-ui` (React frontend, port 8000)
  - `production-multiwoven-worker` (Background jobs)
- **Ingress:**
  - API: `multiwoven-api.igual.cloud` (ALB)
  - UI: `multiwoven.igual.cloud` (ALB)

**Environment Variables (ConfigMap):**
```yaml
USER_EMAIL_VERIFICATION: "true"
ALLOWED_EMAIL_DOMAINS: "igual.com"
SMTP_BRAND_NAME: "igual"
VITE_BRAND_NAME: "igual Data Platform"
CORS_ALLOWED_ORIGINS: "https://multiwoven.igual.cloud"
```

**Secrets (AWS Secrets Manager → External Secrets):**
- Secret ID: `production-multiwoven`
- Keys: `smtp_host`, `smtp_port`, `smtp_address`, `smtp_username`, `smtp_password`, `smtp_sender_email`, `db_password`, etc.

### 4. Migration from Init Container

**Previous Approach (Removed):**
Kubernetes init container injected custom initializers at runtime via volume mounts:
```yaml
initContainers:
  - name: custom-initializers
    image: busybox
    command: [sh, -c, "cat > /app-config/..."]
```

**Current Approach:**
Custom initializers are committed to this fork and baked into the Docker image during CI/CD build.

**Benefits:**
- ✅ Simpler deployment (no init container complexity)
- ✅ Version controlled (changes tracked in git)
- ✅ Faster pod startup (no init container delay)
- ✅ Portable (image is self-contained)

**To Deploy Custom Image:**
1. Merge changes to `main` → CI builds image
2. Update `kubernetes/production/data/multiwoven/values.yaml`:
   ```yaml
   multiwovenServer:
     image:
       repository: 992382838579.dkr.ecr.sa-east-1.amazonaws.com/multiwoven-server
       tag: <git-sha-or-latest>
   ```
3. Remove init container section from `deployments/server.yaml`
4. ArgoCD sync

## Development Workflow

### Making Changes to Initializers

1. Edit files in `server/config/initializers/`
2. Test locally (optional): `docker build -f server/Dockerfile -t multiwoven-test .`
3. Commit and push to `main`
4. GitHub Actions builds and pushes to ECR automatically
5. Update Helm chart with new image tag
6. Deploy via ArgoCD

### Testing Locally

```bash
# Build image
docker build -f server/Dockerfile -t multiwoven-igual:local .

# Run with igual config
docker run -e USER_EMAIL_VERIFICATION=true \
           -e ALLOWED_EMAIL_DOMAINS=igual.com \
           -e SMTP_HOST=multiwoven.igual.cloud \
           -p 3000:3000 \
           multiwoven-igual:local
```

### Syncing with Upstream

This fork is based on Multiwoven's main branch. To sync with upstream:

```bash
git remote add upstream git@github.com:Multiwoven/multiwoven.git
git fetch upstream
git merge upstream/main
# Resolve conflicts (especially in rails_host_authorization.rb)
git push origin main
```

**Important:** When merging upstream changes, ensure custom initializers are preserved:
- `rails_host_authorization.rb` - Keep igual's version (disabled)
- `restrict_email_domains.rb` - Keep (igual-only)
- `fix_action_mailer_urls.rb` - Keep (igual-only)

## Troubleshooting

### Email Verification Links Not Working

**Symptom:** Users receive email but link shows redirect warning or relative URL

**Check:**
1. Verify `SMTP_HOST=multiwoven.igual.cloud` in Secrets Manager
2. Check logs for: `✅ ActionMailer URLs configured: https://multiwoven.igual.cloud`
3. If missing, ensure `fix_action_mailer_urls.rb` exists in the image
4. Force External Secret sync: `kubectl annotate externalsecret multiwoven-credentials -n data force-sync="$(date +%s)"`

### ALB Health Checks Failing (403 Errors)

**Symptom:** Targets unhealthy in ALB, pod logs show "Blocked hosts" errors

**Check:**
1. Verify `rails_host_authorization.rb` has igual's version (disabled HostAuthorization)
2. Check if init container or custom image is being used
3. Ensure ALB health check path is `/` (not `/api/v1/health`)

### Email Domain Restrictions Not Working

**Symptom:** Users with `@gmail.com` can sign up despite restrictions

**Check:**
1. Verify `ALLOWED_EMAIL_DOMAINS=igual.com` in ConfigMap
2. Check logs for: `🚫 Blocked signup attempt: user@gmail.com`
3. Ensure `restrict_email_domains.rb` exists in the image
4. Verify `before_create` callback is present (validation alone isn't enough)

### Image Build Failures

**Symptom:** GitHub Actions workflow fails during Docker build

**Check:**
1. Review workflow logs in GitHub Actions
2. Ensure `server/Dockerfile` hasn't been corrupted
3. Verify all build scripts exist: `getoracleinstantclient.sh`, `getduckdb.sh`, etc.
4. Check ECR repository permissions

## Related Documentation

- **Upstream:** https://github.com/Multiwoven/multiwoven
- **Deployment Repo:** `igualparatodos/kubernetes/production/data/multiwoven/`
- **CI Workflows:** `igualparatodos/ci-workflows` (reusable workflows)

## Version History

- **2025-11-13:** Initial fork with custom initializers
  - Disabled HostAuthorization for ALB health checks
  - Added email domain restrictions (`@igual.com` only)
  - Fixed email verification URLs (absolute HTTPS links)
  - Created GitHub Actions workflow for ECR builds

## Maintainers

- igual Platform Team
- Repository: `igualparatodos/multiwoven`
- Contact: DevOps team for deployment questions
