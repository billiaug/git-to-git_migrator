# GitHub Organization Migration Tool

Migrate all repositories from one GitHub organization to another using [GitHub Enterprise Importer](https://github.com/github/gh-gei) (`gh gei`).

## Features

- Migrate all repos between GitHub organizations in one command
- Real-time streaming output for each migration
- Preserve or override repository visibility (public/private/internal)
- Link migrated repos to a GitHub Project (V2)
- Add GitHub Topics to migrated repos
- Grant organization teams access with configurable permissions
- Archive source repos (read-only) after migration
- Delete source repos after migration (with safety confirmation)
- Exclude specific repos from migration
- Dry-run mode to preview without making changes

## Prerequisites

1. **GitHub CLI** - Install from [cli.github.com](https://cli.github.com)

2. **GEI extension** - Install the GitHub Enterprise Importer CLI extension:
   ```bash
   gh extension install github/gh-gei
   ```

3. **Personal Access Tokens** - Create two **classic** PATs (fine-grained tokens are not supported by GEI):

   | Token | Scopes | Used for |
   |-------|--------|----------|
   | Source PAT | `admin:org`, `repo` | Reading source org repos, archiving/deleting |
   | Target PAT | `admin:org`, `repo`, `workflow`, `project` | Creating repos, linking projects, team access |

   Create tokens at: [github.com/settings/tokens](https://github.com/settings/tokens)

4. **jq** - JSON processor (usually pre-installed on macOS/Linux)

## Quick Start

```bash
# Clone this repo
git clone https://github.com/your-org/github-to-github.git
cd github-to-github

# Make executable
chmod +x migrate.sh

# Preview what would be migrated
./migrate.sh \
    --source-org old-org \
    --target-org new-org \
    --source-pat ghp_xxxxxxxxxxxx \
    --target-pat ghp_yyyyyyyyyyyy \
    --dry-run

# Run the migration
./migrate.sh \
    --source-org old-org \
    --target-org new-org \
    --source-pat ghp_xxxxxxxxxxxx \
    --target-pat ghp_yyyyyyyyyyyy
```

## Usage

```
./migrate.sh --source-org <org> --target-org <org> --source-pat <token> --target-pat <token> [OPTIONS]
```

### Required Flags

| Flag | Description |
|------|-------------|
| `--source-org <org>` | Source GitHub organization |
| `--target-org <org>` | Target GitHub organization |
| `--source-pat <token>` | Classic PAT for source org |
| `--target-pat <token>` | Classic PAT for target org |

### Optional Flags

| Flag | Description |
|------|-------------|
| `--exclude <repos>` | Comma-separated list of repo names to skip |
| `--archive-source` | Archive source repos after migration (read-only) |
| `--delete-source` | Delete source repos after migration |
| `--dry-run` | List repos that would be migrated, don't migrate |
| `--target-visibility <vis>` | Set target repo visibility: `private`, `public`, `internal` (default: preserve original) |
| `--skip-releases` | Skip releases during migration (use if >10GB releases) |
| `--target-project <number>` | Link migrated repos to a GitHub Project in target org |
| `--topics <topics>` | Comma-separated GitHub Topics to add to migrated repos |
| `--team <slug:perm>` | Grant a team access to migrated repos (can be repeated) |
| `--yes` | Skip confirmation prompts (except archive/delete confirmations) |
| `-h, --help` | Show help message |

## Examples

### Dry run

Preview which repos will be migrated:

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --dry-run
```

### Exclude specific repos

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --exclude "archived-project,temp-repo,test-sandbox"
```

### Archive source repos after migration

Marks source repos as read-only. Requires typing the org name to confirm.

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --archive-source
```

### Delete source repos after migration

Permanently deletes source repos. Requires typing the org name to confirm.

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --delete-source
```

> **Note:** `--archive-source` and `--delete-source` cannot be used together.

### Link to a GitHub Project

Find your project number first:

```bash
gh project list --owner new-org
```

Then migrate and link:

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --target-project 5
```

### Add topics to migrated repos

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --topics "migrated,legacy,old-org"
```

### Grant team access

Use the team slug (visible in the team URL) and a permission level. Can be repeated for multiple teams.

```bash
./migrate.sh \
    --source-org old-org --target-org new-org \
    --source-pat ghp_xxx --target-pat ghp_yyy \
    --team "developers:push" \
    --team "devops:admin" \
    --team "qa-team:pull"
```

**Available permissions:** `pull` (read), `push` (write), `triage`, `maintain`, `admin`

### Full example with all options

```bash
./migrate.sh \
    --source-org old-org \
    --target-org new-org \
    --source-pat ghp_xxx \
    --target-pat ghp_yyy \
    --exclude "temp-repo,sandbox" \
    --target-visibility private \
    --target-project 3 \
    --topics "migrated,from-old-org" \
    --team "engineering:push" \
    --team "platform:admin" \
    --archive-source
```

## How It Works

1. **Validates** prerequisites (gh CLI, gei extension, PATs, teams, project)
2. **Fetches** all repos from the source org
3. **Filters** out excluded repos
4. **Shows** a migration plan and asks for confirmation
5. **Migrates** each repo sequentially using `gh gei migrate-repo`
6. **Post-migration** per repo (if configured):
   - Links to GitHub Project
   - Adds topics
   - Grants team access
7. **Post-migration** batch (if configured):
   - Archives source repos (requires org name confirmation)
   - Deletes source repos (requires org name confirmation)
8. **Prints** final summary with counts

## Safety Features

- **Dry-run mode** - preview without making changes
- **Confirmation prompts** - before migration starts
- **Separate confirmation for destructive actions** - archive and delete require typing the org name
- **Archive and delete are mutually exclusive** - prevents accidental double-action
- **Sequential migration** - one repo at a time for reliability and easy debugging
- **Non-blocking post-migration steps** - if topics or team access fails, migration is still counted as successful

## Troubleshooting

### "A migration with the same target repo name has already been queued"

A previous migration for this repo is still in progress. Wait for it to complete or re-run the script later. Already-migrated repos will fail with this message and the script will continue with the next repo.

### Script appears to hang

Migration can take several minutes per repo depending on size. The script streams `gh gei` output in real-time, so you should see progress lines. Large repos with many releases take longer (use `--skip-releases` if releases exceed 10GB).

### Team validation fails

Ensure the team slug is correct (lowercase, hyphens instead of spaces). List available teams:

```bash
gh api "/orgs/your-org/teams" --jq '.[].slug'
```

### Token permission errors

Ensure you are using **classic** PATs (not fine-grained) with the correct scopes. If using `--target-project`, the target PAT also needs the `project` scope:

```bash
gh auth refresh -s project
```
