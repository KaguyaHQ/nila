# Nila production on AWS

Nila runs as a single ARM64 Docker Compose stack on EC2 in Hyderabad.

- Region: `ap-south-2`
- Instance: `i-0547b7fd7907f3a21` (`t4g.small`)
- Public IP: `18.61.186.180`
- Disk: encrypted 50 GB gp3
- Services: Caddy, Phoenix, PostgreSQL
- Access: AWS Systems Manager; SSH is closed

Cloudflare proxies `nila.tax`. The `www.nila.tax`, `nilahq.com`, and
`www.nilahq.com` hostnames redirect to it.

## Deploy

Every push to `main` builds `linux/arm64` on GitHub Actions, publishes the image
to GHCR, and invokes `/opt/nila/deploy.sh` through Systems Manager. GitHub assumes
`NilaGitHubDeployRole` through OIDC; the repository stores no AWS access key.

Run a deployment manually with:

```bash
./scripts/deploy.sh
```

## Operations

Open a remote IEx console with:

```bash
./scripts/prod-console
```

This requires AWS CLI v2 and the AWS Session Manager plugin. Check production
without opening a shell at `https://nila.tax/health`.

Runtime configuration is stored in the SSM parameters `/nila/production/env`
and `/nila/production/ghcr-config`. The instance keeps the Compose project under
`/opt/nila`; PostgreSQL data lives in the `nila_nila_pgdata` Docker volume.

The pre-migration database dump is retained on the former shared server at
`/home/deploy/nila/backups/nila-before-aws-2026-09-03.dump` and locally outside
the repository at `D:\nila-backups\nila-before-aws-2026-09-03.dump`.

No automated database backup is configured yet. Add encrypted off-instance
backups before storing customer production data.
