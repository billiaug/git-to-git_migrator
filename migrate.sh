#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GitHub Organization Migration Tool
# Migrates all repositories from one GitHub org to another using gh gei.
#
# Prerequisites:
#   - gh CLI installed (https://cli.github.com)
#   - gh gei extension installed: gh extension install github/gh-gei
#   - Classic PATs (not fine-grained):
#       Source PAT scopes: admin:org, repo
#       Target PAT scopes: admin:org, repo, workflow, project
#   - Pass PATs via flags:
#       --source-pat <token>  - PAT for source organization
#       --target-pat <token>  - PAT for target organization
# =============================================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Defaults ---
SOURCE_ORG=""
TARGET_ORG=""
EXCLUDE_LIST=""
ARCHIVE_SOURCE=false
DELETE_SOURCE=false
DRY_RUN=false
TARGET_VISIBILITY=""
SKIP_RELEASES=false
TARGET_PROJECT=""
TOPICS=""
TEAMS=()
YES=false
GH_SOURCE_PAT=""
GH_PAT=""

# --- Counters ---
MIGRATED=0
FAILED=0
SKIPPED=0
DELETED=0
ARCHIVED=0
LINKED=0
TAGGED=0
TEAM_ASSIGNED=0

# --- Arrays ---
FAILED_REPOS=()
SUCCESS_REPOS=()

usage() {
    cat <<EOF
${BOLD}GitHub Organization Migration Tool${NC}

Migrate all repositories from one GitHub organization to another
using GitHub Enterprise Importer (gh gei).

${BOLD}USAGE:${NC}
    $(basename "$0") --source-org <org> --target-org <org> [OPTIONS]

${BOLD}REQUIRED:${NC}
    --source-org <org>          Source GitHub organization
    --target-org <org>          Target GitHub organization
    --source-pat <token>        Classic PAT for source org (scopes: admin:org, repo)
    --target-pat <token>        Classic PAT for target org (scopes: admin:org, repo, workflow, project)

${BOLD}OPTIONS:${NC}
    --exclude <repos>           Comma-separated list of repo names to skip
    --archive-source            Archive source repos after successful migration
                                (marks as read-only, requires confirmation)
    --delete-source             Delete source repos after successful migration
                                (off by default, requires separate confirmation)
    --dry-run                   List repos that would be migrated, don't migrate
    --target-visibility <vis>   Set target repo visibility: private, public, internal
                                (default: preserve original visibility)
    --skip-releases             Skip releases during migration (use if >10GB releases)
    --target-project <number>   Link migrated repos to a GitHub Project in target org
                                (use 'gh project list --owner <org>' to find the number)
    --topics <topics>           Comma-separated GitHub Topics to add to migrated repos
                                (e.g. "migrated,frontend,legacy")
    --team <slug:perm>          Grant a team access to migrated repos in target org
                                Format: "team-slug:permission" (can be repeated)
                                Permissions: pull, push, admin, maintain, triage
                                (e.g. --team "developers:push" --team "qa:pull")
    --yes                       Skip confirmation prompts (except delete confirmation)
    -h, --help                  Show this help message

${BOLD}EXAMPLES:${NC}
    # Dry run to see what would be migrated
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --dry-run

    # Migrate all repos
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy

    # Migrate all repos except two
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --exclude "repo1,repo2"

    # Migrate and archive source repos (read-only)
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --archive-source

    # Migrate and delete source repos
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --delete-source

    # Migrate and link repos to a GitHub Project
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --target-project 5

    # Migrate and tag repos with topics
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy --topics "migrated,legacy"

    # Migrate and grant team access
    $(basename "$0") --source-org old-org --target-org new-org \\
        --source-pat ghp_xxx --target-pat ghp_yyy \\
        --team "developers:push" --team "devops:admin"
EOF
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
log_header()  { echo -e "\n${BOLD}=== $* ===${NC}\n"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-org)
            SOURCE_ORG="$2"; shift 2 ;;
        --target-org)
            TARGET_ORG="$2"; shift 2 ;;
        --source-pat)
            GH_SOURCE_PAT="$2"; shift 2 ;;
        --target-pat)
            GH_PAT="$2"; shift 2 ;;
        --exclude)
            EXCLUDE_LIST="$2"; shift 2 ;;
        --archive-source)
            ARCHIVE_SOURCE=true; shift ;;
        --delete-source)
            DELETE_SOURCE=true; shift ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --target-visibility)
            TARGET_VISIBILITY="$2"; shift 2 ;;
        --skip-releases)
            SKIP_RELEASES=true; shift ;;
        --target-project)
            TARGET_PROJECT="$2"; shift 2 ;;
        --topics)
            TOPICS="$2"; shift 2 ;;
        --team)
            TEAMS+=("$2"); shift 2 ;;
        --yes)
            YES=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1 ;;
    esac
done

# --- Validate required args ---
if [[ -z "$SOURCE_ORG" || -z "$TARGET_ORG" || -z "$GH_SOURCE_PAT" || -z "$GH_PAT" ]]; then
    log_error "--source-org, --target-org, --source-pat, and --target-pat are all required."
    echo "Run '$(basename "$0") --help' for usage."
    exit 1
fi

if [[ "$ARCHIVE_SOURCE" == true && "$DELETE_SOURCE" == true ]]; then
    log_error "Cannot use both --archive-source and --delete-source. Choose one."
    exit 1
fi

if [[ -n "$TARGET_VISIBILITY" && ! "$TARGET_VISIBILITY" =~ ^(private|public|internal)$ ]]; then
    log_error "Invalid --target-visibility: $TARGET_VISIBILITY (must be private, public, or internal)"
    exit 1
fi

if [[ -n "$TARGET_PROJECT" && ! "$TARGET_PROJECT" =~ ^[0-9]+$ ]]; then
    log_error "Invalid --target-project: $TARGET_PROJECT (must be a project number)"
    echo "  Run: gh project list --owner <target-org>  to find project numbers."
    exit 1
fi

# --- Validate prerequisites ---
log_header "Checking prerequisites"

if ! command -v gh &>/dev/null; then
    log_error "gh CLI is not installed. Install from https://cli.github.com"
    exit 1
fi
log_success "gh CLI found"

if ! gh extension list 2>/dev/null | grep -q "gh-gei"; then
    log_error "gh gei extension is not installed. Run: gh extension install github/gh-gei"
    exit 1
fi
log_success "gh gei extension found"

if [[ -z "$GH_SOURCE_PAT" ]]; then
    log_error "--source-pat is required."
    echo "  Create a classic PAT with scopes: admin:org, repo"
    exit 1
fi
log_success "Source PAT provided"

if [[ -z "$GH_PAT" ]]; then
    log_error "--target-pat is required."
    echo "  Create a classic PAT with scopes: admin:org, repo, workflow, project"
    exit 1
fi
log_success "Target PAT provided"

# Export for gh gei (it reads GH_PAT from env)
export GH_PAT
export GH_SOURCE_PAT

# --- Validate teams ---
if [[ ${#TEAMS[@]} -gt 0 ]]; then
    for team_entry in "${TEAMS[@]}"; do
        if [[ "$team_entry" != *":"* ]]; then
            log_error "Invalid --team format: ${team_entry}"
            echo "  Expected format: team-slug:permission (e.g. developers:push)"
            exit 1
        fi
        t_slug="${team_entry%%:*}"
        t_perm="${team_entry##*:}"
        if [[ ! "$t_perm" =~ ^(pull|push|admin|maintain|triage)$ ]]; then
            log_error "Invalid permission '${t_perm}' for team '${t_slug}'"
            echo "  Valid permissions: pull, push, admin, maintain, triage"
            exit 1
        fi
        # Verify team exists in target org
        log_info "Validating team '${t_slug}' in ${TARGET_ORG}..."
        if ! GH_TOKEN="$GH_PAT" gh api "/orgs/${TARGET_ORG}/teams/${t_slug}" --silent 2>/dev/null; then
            log_error "Team '${t_slug}' not found in ${TARGET_ORG}."
            echo "  Available teams:"
            GH_TOKEN="$GH_PAT" gh api "/orgs/${TARGET_ORG}/teams" --jq '.[].slug' 2>/dev/null | sed 's/^/    /' || echo "    (could not list teams)"
            exit 1
        fi
        log_success "Team validated: ${t_slug} (${t_perm})"
    done
fi

# --- Validate target project exists ---
if [[ -n "$TARGET_PROJECT" ]]; then
    log_info "Validating project #${TARGET_PROJECT} in ${TARGET_ORG}..."
    PROJECT_TITLE=$(GH_TOKEN="$GH_PAT" gh project view "$TARGET_PROJECT" --owner "$TARGET_ORG" --format json --jq '.title' 2>&1) || {
        log_error "Project #${TARGET_PROJECT} not found in ${TARGET_ORG}."
        echo "  Available projects:"
        GH_TOKEN="$GH_PAT" gh project list --owner "$TARGET_ORG" --format json --jq '.projects[] | "    #\(.number) - \(.title)"' 2>&1 || echo "    (could not list projects)"
        echo "  Ensure your GH_PAT has the 'project' scope: gh auth refresh -s project"
        exit 1
    }
    log_success "Target project: #${TARGET_PROJECT} - ${PROJECT_TITLE}"
fi

# --- Fetch repos from source org ---
log_header "Fetching repositories from ${SOURCE_ORG}"

REPOS_JSON=$(GH_TOKEN="$GH_SOURCE_PAT" gh repo list "$SOURCE_ORG" --json name,visibility --limit 999 2>&1) || {
    log_error "Failed to list repos in ${SOURCE_ORG}. Check your GH_SOURCE_PAT and org name."
    echo "$REPOS_JSON"
    exit 1
}

REPO_COUNT=$(echo "$REPOS_JSON" | jq length)
if [[ "$REPO_COUNT" -eq 0 ]]; then
    log_warn "No repositories found in ${SOURCE_ORG}."
    exit 0
fi
log_info "Found ${REPO_COUNT} repositories in ${SOURCE_ORG}"

# --- Build exclude set (bash 3 compatible, uses delimiter-separated string) ---
EXCLUDE_STRING=""
if [[ -n "$EXCLUDE_LIST" ]]; then
    EXCLUDE_COUNT=0
    IFS=',' read -ra EXCLUDES <<< "$EXCLUDE_LIST"
    for repo in "${EXCLUDES[@]}"; do
        trimmed=$(echo "$repo" | xargs)
        EXCLUDE_STRING="|${trimmed}${EXCLUDE_STRING}"
        EXCLUDE_COUNT=$((EXCLUDE_COUNT + 1))
    done
    EXCLUDE_STRING="${EXCLUDE_STRING}|"
    log_info "Excluding ${EXCLUDE_COUNT} repos: ${EXCLUDE_LIST}"
fi

is_excluded() {
    local name="$1"
    [[ -n "$EXCLUDE_STRING" && "$EXCLUDE_STRING" == *"|${name}|"* ]]
}

# --- Build migration list ---
MIGRATE_NAMES=()
MIGRATE_VISIBILITY=()

for i in $(seq 0 $((REPO_COUNT - 1))); do
    name=$(echo "$REPOS_JSON" | jq -r ".[$i].name")
    visibility=$(echo "$REPOS_JSON" | jq -r ".[$i].visibility")

    if is_excluded "$name"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    MIGRATE_NAMES+=("$name")
    MIGRATE_VISIBILITY+=("$visibility")
done

TOTAL=${#MIGRATE_NAMES[@]}

if [[ "$TOTAL" -eq 0 ]]; then
    log_warn "No repositories to migrate after applying exclusions."
    exit 0
fi

# --- Show summary ---
log_header "Migration plan"
echo -e "${BOLD}Source:${NC}  ${SOURCE_ORG}"
echo -e "${BOLD}Target:${NC} ${TARGET_ORG}"
echo -e "${BOLD}Repos:${NC}  ${TOTAL} to migrate, ${SKIPPED} excluded"
if [[ -n "$TARGET_PROJECT" ]]; then
    echo -e "${BOLD}Project:${NC} #${TARGET_PROJECT} - ${PROJECT_TITLE}"
fi
if [[ -n "$TOPICS" ]]; then
    echo -e "${BOLD}Topics:${NC}  ${TOPICS}"
fi
if [[ ${#TEAMS[@]} -gt 0 ]]; then
    echo -e "${BOLD}Teams:${NC}"
    for team_entry in "${TEAMS[@]}"; do
        t_slug="${team_entry%%:*}"
        t_perm="${team_entry##*:}"
        echo -e "          ${t_slug} (${t_perm})"
    done
fi
if [[ "$ARCHIVE_SOURCE" == true ]]; then
    echo -e "${BOLD}Archive:${NC} ${YELLOW}Source repos will be archived (read-only) after migration${NC}"
fi
if [[ "$DELETE_SOURCE" == true ]]; then
    echo -e "${BOLD}Delete:${NC} ${RED}Source repos will be deleted after migration${NC}"
fi
echo ""

printf "  %-40s %s\n" "REPOSITORY" "VISIBILITY"
printf "  %-40s %s\n" "----------------------------------------" "----------"
for i in "${!MIGRATE_NAMES[@]}"; do
    printf "  %-40s %s\n" "${MIGRATE_NAMES[$i]}" "${MIGRATE_VISIBILITY[$i]}"
done
echo ""

# --- Dry run exit ---
if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry run complete. No changes were made."
    exit 0
fi

# --- Confirmation ---
if [[ "$YES" != true ]]; then
    echo -en "${BOLD}Proceed with migration? [y/N]:${NC} "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled."
        exit 0
    fi
fi

# --- Migrate repos ---
log_header "Starting migration"

for i in "${!MIGRATE_NAMES[@]}"; do
    name="${MIGRATE_NAMES[$i]}"
    visibility="${MIGRATE_VISIBILITY[$i]}"
    idx=$((i + 1))

    echo -e "\n${BOLD}[${idx}/${TOTAL}]${NC} Migrating ${BOLD}${name}${NC}..."

    # Build gei command
    cmd=(gh gei migrate-repo
        --github-source-org "$SOURCE_ORG"
        --source-repo "$name"
        --github-target-org "$TARGET_ORG"
        --target-repo "$name"
    )

    # Set visibility
    if [[ -n "$TARGET_VISIBILITY" ]]; then
        cmd+=(--target-repo-visibility "$TARGET_VISIBILITY")
    else
        # Preserve original visibility (gh reports UPPER, gei expects lower)
        lower_vis=$(echo "$visibility" | tr '[:upper:]' '[:lower:]')
        cmd+=(--target-repo-visibility "$lower_vis")
    fi

    if [[ "$SKIP_RELEASES" == true ]]; then
        cmd+=(--skip-releases)
    fi

    # Run migration (stream output in real-time via tee)
    TMPLOG=$(mktemp)
    set +e
    "${cmd[@]}" 2>&1 | tee "$TMPLOG"
    exit_code=${PIPESTATUS[0]}
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
        log_success "${name} - migrated successfully"
        MIGRATED=$((MIGRATED + 1))
        SUCCESS_REPOS+=("$name")

        # Link to target project
        if [[ -n "$TARGET_PROJECT" ]]; then
            if GH_TOKEN="$GH_PAT" gh project link "$TARGET_PROJECT" --owner "$TARGET_ORG" --repo "${TARGET_ORG}/${name}" 2>&1; then
                log_success "${name} - linked to project #${TARGET_PROJECT}"
                LINKED=$((LINKED + 1))
            else
                log_warn "${name} - migrated but failed to link to project #${TARGET_PROJECT}"
            fi
        fi

        # Add topics
        if [[ -n "$TOPICS" ]]; then
            topic_fail=false
            IFS=',' read -ra TOPIC_LIST <<< "$TOPICS"
            for topic in "${TOPIC_LIST[@]}"; do
                topic=$(echo "$topic" | xargs)
                if ! GH_TOKEN="$GH_PAT" gh repo edit "${TARGET_ORG}/${name}" --add-topic "$topic" 2>&1; then
                    topic_fail=true
                fi
            done
            if [[ "$topic_fail" == false ]]; then
                log_success "${name} - topics added: ${TOPICS}"
                TAGGED=$((TAGGED + 1))
            else
                log_warn "${name} - some topics failed to apply"
            fi
        fi

        # Grant team access
        if [[ ${#TEAMS[@]} -gt 0 ]]; then
            team_all_ok=true
            for team_entry in "${TEAMS[@]}"; do
                t_slug="${team_entry%%:*}"
                t_perm="${team_entry##*:}"
                if GH_TOKEN="$GH_PAT" gh api --method PUT \
                    "/orgs/${TARGET_ORG}/teams/${t_slug}/repos/${TARGET_ORG}/${name}" \
                    -f "permission=${t_perm}" --silent 2>/dev/null; then
                    log_success "${name} - team '${t_slug}' granted ${t_perm} access"
                else
                    log_warn "${name} - failed to grant '${t_slug}' access"
                    team_all_ok=false
                fi
            done
            if [[ "$team_all_ok" == true ]]; then
                TEAM_ASSIGNED=$((TEAM_ASSIGNED + 1))
            fi
        fi
    else
        log_error "${name} - migration failed"
        FAILED=$((FAILED + 1))
        FAILED_REPOS+=("$name")
    fi
    rm -f "$TMPLOG"
done

# --- Archive source repos ---
if [[ "$ARCHIVE_SOURCE" == true && ${#SUCCESS_REPOS[@]} -gt 0 ]]; then
    log_header "Archive source repositories"

    echo -e "${YELLOW}${BOLD}This will archive ${#SUCCESS_REPOS[@]} repos in ${SOURCE_ORG} (read-only).${NC}"
    echo "Repos to archive:"
    for repo in "${SUCCESS_REPOS[@]}"; do
        echo "  - ${repo}"
    done
    echo ""

    echo -en "${YELLOW}${BOLD}Type the source org name (${SOURCE_ORG}) to confirm archiving:${NC} "
    read -r archive_confirm

    if [[ "$archive_confirm" != "$SOURCE_ORG" ]]; then
        log_warn "Archiving cancelled. Source repos were NOT archived."
    else
        for repo in "${SUCCESS_REPOS[@]}"; do
            echo -n "  Archiving ${SOURCE_ORG}/${repo}..."
            if GH_TOKEN="$GH_SOURCE_PAT" gh repo archive "${SOURCE_ORG}/${repo}" --yes 2>&1; then
                echo -e " ${GREEN}done${NC}"
                ARCHIVED=$((ARCHIVED + 1))
            else
                echo -e " ${RED}failed${NC}"
            fi
        done
    fi
fi

# --- Delete source repos ---
if [[ "$DELETE_SOURCE" == true && ${#SUCCESS_REPOS[@]} -gt 0 ]]; then
    log_header "Delete source repositories"

    echo -e "${RED}${BOLD}WARNING: This will permanently delete ${#SUCCESS_REPOS[@]} repos from ${SOURCE_ORG}.${NC}"
    echo "Repos to delete:"
    for repo in "${SUCCESS_REPOS[@]}"; do
        echo "  - ${repo}"
    done
    echo ""

    echo -en "${RED}${BOLD}Type the source org name (${SOURCE_ORG}) to confirm deletion:${NC} "
    read -r delete_confirm

    if [[ "$delete_confirm" != "$SOURCE_ORG" ]]; then
        log_warn "Deletion cancelled. Source repos were NOT deleted."
    else
        for repo in "${SUCCESS_REPOS[@]}"; do
            echo -n "  Deleting ${SOURCE_ORG}/${repo}..."
            if GH_TOKEN="$GH_SOURCE_PAT" gh repo delete "${SOURCE_ORG}/${repo}" --yes 2>&1; then
                echo -e " ${GREEN}done${NC}"
                DELETED=$((DELETED + 1))
            else
                echo -e " ${RED}failed${NC}"
            fi
        done
    fi
fi

# --- Final summary ---
log_header "Migration complete"

echo -e "  ${GREEN}Migrated:${NC}  ${MIGRATED}"
echo -e "  ${RED}Failed:${NC}    ${FAILED}"
echo -e "  ${YELLOW}Skipped:${NC}   ${SKIPPED}"
if [[ -n "$TARGET_PROJECT" ]]; then
    echo -e "  ${BLUE}Linked:${NC}    ${LINKED}"
fi
if [[ -n "$TOPICS" ]]; then
    echo -e "  ${BLUE}Tagged:${NC}    ${TAGGED}"
fi
if [[ ${#TEAMS[@]} -gt 0 ]]; then
    echo -e "  ${BLUE}Teams:${NC}     ${TEAM_ASSIGNED}"
fi
if [[ "$ARCHIVE_SOURCE" == true ]]; then
    echo -e "  ${YELLOW}Archived:${NC}  ${ARCHIVED}"
fi
if [[ "$DELETE_SOURCE" == true ]]; then
    echo -e "  ${RED}Deleted:${NC}   ${DELETED}"
fi

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
    echo -e "\n${RED}Failed repos:${NC}"
    for repo in "${FAILED_REPOS[@]}"; do
        echo "  - ${repo}"
    done
fi

# Exit with error if any migration failed
if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
