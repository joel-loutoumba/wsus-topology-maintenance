# WSUS Toolkit

A small, coherent set of PowerShell tools and a runbook to **remediate, maintain and
troubleshoot a WSUS topology** (upstream + downstream/replica servers) end to end.

Built and battle-tested against a real multi-server WSUS environment, then fully
anonymized for public use. Every value is parameterized — no hostnames, domains,
addresses or credentials are hard-coded.

## The workflow

The tools are meant to be used in this order:

```
1. INITIAL REMEDIATION        2. MONTHLY MAINTENANCE          3. CLIENT TROUBLESHOOTING
   (one-time, per server,        (scheduled, whole topology,     (when clients report
    local)                        e-mail report)                  update errors)
   Repair-WsusDatabase.ps1  -->  Invoke-WsusMaintenance.ps1  -->  docs/client-update-
                                                                  troubleshooting.md
   Invoke-WsusContentCleanup.ps1 is a resilient, on-demand cleanup used alongside 1 & 2.
```

| Step | Tool | Scope | When |
|---|---|---|---|
| 1. Remediation | `scripts/Repair-WsusDatabase.ps1` | One server, **run locally** | Once, on a neglected/bloated server (indexes, reindex, drain obsolete updates without timing out) |
| 2. Maintenance | `scripts/Invoke-WsusMaintenance.ps1` | **Whole topology**, via API | Monthly, scheduled; declines x86, cleans up, e-mails a consolidated health + actions report |
| — Cleanup | `scripts/Invoke-WsusContentCleanup.ps1` | One server, local or remote | On demand; resilient (progress, no global timeout) alternative to the native cleanup |
| 3. Troubleshooting | `docs/client-update-troubleshooting.md` | Clients | When the report flags clients in error |

### Why two layers (API vs. local SQL)?

- The **maintenance** script is API-based, so a single run maintains every server in the
  topology, including remote ones. But the native cleanup it calls can **time out** on a
  WSUS database that has never been maintained.
- The **remediation** script works directly against the WSUS database (SUSDB) to create
  the missing indexes and drain the obsolete-update backlog one row at a time (no global
  timeout). SUSDB on Windows Internal Database (WID) is only reachable **locally**, so this
  step is run on each server once, up front.

After each server has been remediated once, the monthly maintenance runs in minutes.

## Repository layout

```
wsus-toolkit/
├── README.md
├── LICENSE
├── .gitignore
├── scripts/
│   ├── Repair-WsusDatabase.ps1          # 1. one-time DB remediation (local)
│   ├── Invoke-WsusMaintenance.ps1       # 2. monthly topology maintenance + report
│   └── Invoke-WsusContentCleanup.ps1    #    resilient on-demand cleanup
└── docs/
    └── client-update-troubleshooting.md # 3. technician runbook
```

## Quick start

```powershell
# 1) On a neglected server, locally, in a maintenance window:
.\scripts\Repair-WsusDatabase.ps1

# 2) From a management host, simulate first (nothing changes), then run for real:
.\scripts\Invoke-WsusMaintenance.ps1 -ReportOnly
.\scripts\Invoke-WsusMaintenance.ps1

# 3) When clients are flagged in error, follow docs/client-update-troubleshooting.md
```

Each script ships full comment-based help:

```powershell
Get-Help .\scripts\Invoke-WsusMaintenance.ps1 -Full
```

## Requirements

- WSUS role / RSAT (`UpdateServices` PowerShell module), PowerShell 5.1+.
- The running account must be in the local **WSUS Administrators** group on each target
  server; WSUS API ports (8530 / 8531) reachable from the management host.
- `Repair-WsusDatabase.ps1` needs **local** DB access (e.g., `db_owner` on SUSDB) and is run
  on the server itself.
- An SMTP relay for the maintenance report.
- Client troubleshooting at scale uses WinRM.

## Safety & privacy

- Default values are placeholders (`*.example.local`, `WSUS-UPSTREAM`, `DOMAIN\gmsa$`).
- Generated **logs and CSVs may contain real hostnames/IPs** — they are excluded by
  `.gitignore`. Never commit them.
- Test in a non-production environment first.

## License

MIT — see `LICENSE`. Replace `<Your Name>` with your own.

## Disclaimer

Provided as-is, without warranty. You are responsible for validating behavior against your
own WSUS topology before using it in production.
