#!/usr/bin/env bash
# Build the phone controller image from an explicitly selected Forge v4 tree.
# This does not build the optional Ollama stage or the currently unpinned
# operator image.
set -euo pipefail

usage() {
  printf '%s\n' \
    'usage: build-images.sh --source FORGE_V4_GIT_ROOT --manifest OUTPUT.json [--allow-dirty]'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

SOURCE_ARGUMENT=
MANIFEST_ARGUMENT=
ALLOW_DIRTY=false
SOURCE_SEEN=false
MANIFEST_SEEN=false
ALLOW_DIRTY_SEEN=false

while (($# > 0)); do
  case "$1" in
    --source)
      "$SOURCE_SEEN" && die '--source may be specified only once'
      (($# >= 2)) || die '--source requires a value'
      SOURCE_ARGUMENT=$2
      SOURCE_SEEN=true
      shift 2
      ;;
    --manifest)
      "$MANIFEST_SEEN" && die '--manifest may be specified only once'
      (($# >= 2)) || die '--manifest requires a value'
      MANIFEST_ARGUMENT=$2
      MANIFEST_SEEN=true
      shift 2
      ;;
    --allow-dirty)
      "$ALLOW_DIRTY_SEEN" && die '--allow-dirty may be specified only once'
      ALLOW_DIRTY=true
      ALLOW_DIRTY_SEEN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      die 'positional arguments are not accepted'
      ;;
  esac
done

"$SOURCE_SEEN" || die '--source is required'
"$MANIFEST_SEEN" || die '--manifest is required'

case "$MANIFEST_ARGUMENT" in
  */*)
    MANIFEST_PARENT_ARGUMENT=${MANIFEST_ARGUMENT%/*}
    MANIFEST_NAME=${MANIFEST_ARGUMENT##*/}
    [[ -n "$MANIFEST_PARENT_ARGUMENT" ]] || MANIFEST_PARENT_ARGUMENT=/
    ;;
  *)
    MANIFEST_PARENT_ARGUMENT=.
    MANIFEST_NAME=$MANIFEST_ARGUMENT
    ;;
esac

case "$MANIFEST_NAME" in
  ''|.|..)
    die 'manifest output must name a file'
    ;;
esac
[[ "$MANIFEST_NAME" != *$'\n'* && "$MANIFEST_NAME" != *$'\r'* ]] || \
  die 'manifest filename contains an unsupported character'
[[ -d "$MANIFEST_PARENT_ARGUMENT" ]] || die 'manifest parent directory does not exist'
[[ -w "$MANIFEST_PARENT_ARGUMENT" ]] || die 'manifest parent directory is not writable'
MANIFEST_PARENT=$(cd -- "$MANIFEST_PARENT_ARGUMENT" && pwd -P) || \
  die 'cannot resolve manifest parent directory'
MANIFEST_PATH=$MANIFEST_PARENT/$MANIFEST_NAME
if [[ -e "$MANIFEST_PATH" || -L "$MANIFEST_PATH" ]]; then
  die 'manifest output already exists'
fi

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || \
  die 'cannot resolve builder script directory'
EXPECTED_BUILDER_ROOT=$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P) || \
  die 'cannot resolve companion repository root'

resolve_git_root() {
  local candidate=$1
  local description=$2
  local physical top top_physical

  [[ -d "$candidate" ]] || die "$description is not a directory"
  physical=$(cd -- "$candidate" && pwd -P) || die "cannot resolve $description"
  top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null) || \
    die "$description is not a Git repository"
  [[ -d "$top" ]] || die "$description Git root cannot be resolved"
  top_physical=$(cd -- "$top" && pwd -P) || die "$description Git root cannot be resolved"
  [[ "$physical" == "$top_physical" ]] || die "$description must be the Git top-level directory"
  RESOLVED_GIT_ROOT=$physical
}

resolve_revision() {
  local repository=$1
  local description=$2
  local revision

  revision=$(git -C "$repository" rev-parse --verify HEAD 2>/dev/null) || \
    die "cannot resolve $description HEAD"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "$description HEAD is not a full SHA-1 commit ID"
  RESOLVED_REVISION=$revision
}

resolve_dirty_state() {
  local repository=$1
  local description=$2
  local status_output

  status_output=$(git -C "$repository" status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none 2>/dev/null) || \
    die "cannot inspect $description worktree state"
  if [[ -n "$status_output" ]]; then
    RESOLVED_DIRTY=true
  else
    RESOLVED_DIRTY=false
  fi
}

resolve_git_root "$SOURCE_ARGUMENT" 'Forge v4 source'
SOURCE_ROOT=$RESOLVED_GIT_ROOT
resolve_git_root "$EXPECTED_BUILDER_ROOT" 'Pixel companion repository'
BUILDER_ROOT=$RESOLVED_GIT_ROOT
[[ "$BUILDER_ROOT" == "$EXPECTED_BUILDER_ROOT" ]] || \
  die 'builder script is not inside the Pixel companion Git root'

for REQUIRED_BUILDER_FILE in eip/build-images.sh eip/container.build.env; do
  BUILDER_FILE=$BUILDER_ROOT/$REQUIRED_BUILDER_FILE
  [[ -f "$BUILDER_FILE" && ! -L "$BUILDER_FILE" && -r "$BUILDER_FILE" ]] || \
    die "required tracked builder file is unavailable: $REQUIRED_BUILDER_FILE"
  git -C "$BUILDER_ROOT" ls-files --error-unmatch -- "$REQUIRED_BUILDER_FILE" \
    >/dev/null 2>&1 || die "required builder file is not tracked: $REQUIRED_BUILDER_FILE"
done

for REQUIRED_SOURCE_FILE in \
  .dockerignore \
  deploy/container/Dockerfile \
  package.json \
  package-lock.json; do
  SOURCE_FILE=$SOURCE_ROOT/$REQUIRED_SOURCE_FILE
  [[ -f "$SOURCE_FILE" && ! -L "$SOURCE_FILE" && -r "$SOURCE_FILE" ]] || \
    die "required tracked source file is unavailable: $REQUIRED_SOURCE_FILE"
  git -C "$SOURCE_ROOT" ls-files --error-unmatch -- "$REQUIRED_SOURCE_FILE" \
    >/dev/null 2>&1 || die "required source file is not tracked: $REQUIRED_SOURCE_FILE"
done

resolve_revision "$SOURCE_ROOT" 'Forge v4 source'
SOURCE_REVISION=$RESOLVED_REVISION
resolve_revision "$BUILDER_ROOT" 'Pixel companion repository'
BUILDER_REVISION=$RESOLVED_REVISION
resolve_dirty_state "$SOURCE_ROOT" 'Forge v4 source'
SOURCE_DIRTY=$RESOLVED_DIRTY
resolve_dirty_state "$BUILDER_ROOT" 'Pixel companion repository'
BUILDER_DIRTY=$RESOLVED_DIRTY

if ! "$ALLOW_DIRTY"; then
  [[ "$SOURCE_DIRTY" == false ]] || \
    die 'Forge v4 source is dirty; inspect it or explicitly pass --allow-dirty'
  [[ "$BUILDER_DIRTY" == false ]] || \
    die 'Pixel companion repository is dirty; inspect it or explicitly pass --allow-dirty'
fi

PROFILE_PATH=$SCRIPT_DIRECTORY/container.build.env
[[ -f "$PROFILE_PATH" && ! -L "$PROFILE_PATH" && -r "$PROFILE_PATH" ]] || \
  die 'controller build profile is unavailable'

read_profile_value() {
  local key=$1
  local value

  value=$(awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      count += 1
      result = substr($0, length(wanted) + 2)
    }
    END {
      if (count != 1) exit 3
      print result
    }
  ' "$PROFILE_PATH") || die "build profile must define $key exactly once"
  PROFILE_VALUE=$value
}

read_profile_value EIP_CVE_UID
CONTROLLER_UID=$PROFILE_VALUE
read_profile_value EIP_CVE_GID
CONTROLLER_GID=$PROFILE_VALUE
read_profile_value EIP_CVE_PLATFORM_ARCH
PLATFORM_ARCH=$PROFILE_VALUE
read_profile_value EIP_CVE_IMAGE_TAG
IMAGE_TAG=$PROFILE_VALUE

[[ "$CONTROLLER_UID" =~ ^[1-9][0-9]*$ ]] || die 'EIP_CVE_UID must be a positive decimal integer'
[[ "$CONTROLLER_GID" =~ ^[1-9][0-9]*$ ]] || die 'EIP_CVE_GID must be a positive decimal integer'
[[ "$PLATFORM_ARCH" == arm64 ]] || die 'EIP_CVE_PLATFORM_ARCH must be arm64 for the phone build'
[[ "$IMAGE_TAG" == phone ]] || die 'EIP_CVE_IMAGE_TAG must be phone for the phone build'

CONTROLLER_TAG=eip-cve-controller:$IMAGE_TAG
SOURCE_DIRTY_LABEL=$SOURCE_DIRTY
BUILDER_DIRTY_LABEL=$BUILDER_DIRTY

for REQUIRED_COMMAND in docker tar node mktemp chmod link; do
  command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || die "$REQUIRED_COMMAND is unavailable"
done

TEMP_PARENT_ARGUMENT=${TMPDIR:-/tmp}
[[ -d "$TEMP_PARENT_ARGUMENT" && -w "$TEMP_PARENT_ARGUMENT" ]] || \
  die 'temporary directory is unavailable'
TEMP_PARENT=$(cd -- "$TEMP_PARENT_ARGUMENT" && pwd -P) || \
  die 'cannot resolve temporary directory'

MANIFEST_TEMP=
MANIFEST_LINK_PROBE=
CONTEXT_WORK_ROOT=
cleanup_build_temps() {
  if [[ -n "$MANIFEST_LINK_PROBE" && -e "$MANIFEST_LINK_PROBE" ]]; then
    rm -f -- "$MANIFEST_LINK_PROBE"
  fi
  if [[ -n "$MANIFEST_TEMP" && -e "$MANIFEST_TEMP" ]]; then
    rm -f -- "$MANIFEST_TEMP"
  fi
  if [[ -n "$CONTEXT_WORK_ROOT" && -d "$CONTEXT_WORK_ROOT" ]]; then
    rm -rf -- "$CONTEXT_WORK_ROOT"
  fi
}
trap cleanup_build_temps EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

umask 077
CONTEXT_WORK_ROOT=$(mktemp -d "$TEMP_PARENT/eip-controller-context.XXXXXX") || \
  die 'cannot create controller context workspace'
chmod 700 "$CONTEXT_WORK_ROOT" || die 'cannot protect controller context workspace'
CONTEXT_ARCHIVE=$CONTEXT_WORK_ROOT/context.tar
CONTEXT_ROOT=$CONTEXT_WORK_ROOT/context
mkdir -m 700 "$CONTEXT_ROOT" || die 'cannot create controller context directory'

if [[ "$SOURCE_DIRTY" == false ]]; then
  git -C "$SOURCE_ROOT" archive --format=tar \
    --output="$CONTEXT_ARCHIVE" "$SOURCE_REVISION" || \
    die 'cannot snapshot the committed Forge v4 source'
else
  SOURCE_PATH_LIST=$CONTEXT_WORK_ROOT/source-paths.z
  SNAPSHOT_PATH_LIST=$CONTEXT_WORK_ROOT/snapshot-paths.z
  git -C "$SOURCE_ROOT" ls-files --cached --others --exclude-standard -z \
    > "$SOURCE_PATH_LIST" || die 'cannot enumerate dirty Forge v4 source files'
  : > "$SNAPSHOT_PATH_LIST"
  while IFS= read -r -d '' RELATIVE_SOURCE_PATH; do
    case "$RELATIVE_SOURCE_PATH" in
      ''|/*|../*|*/../*)
        die 'Git returned an unsafe source path'
        ;;
    esac
    if [[ -f "$SOURCE_ROOT/$RELATIVE_SOURCE_PATH" || -L "$SOURCE_ROOT/$RELATIVE_SOURCE_PATH" ]]; then
      printf '%s\0' "$RELATIVE_SOURCE_PATH" >> "$SNAPSHOT_PATH_LIST"
    elif [[ -e "$SOURCE_ROOT/$RELATIVE_SOURCE_PATH" ]]; then
      die 'dirty source contains an unsupported tracked or untracked file type'
    fi
  done < "$SOURCE_PATH_LIST"
  tar -C "$SOURCE_ROOT" --null -T "$SNAPSHOT_PATH_LIST" -cf "$CONTEXT_ARCHIVE" || \
    die 'cannot snapshot the dirty Forge v4 source'
fi

if command -v shasum >/dev/null 2>&1; then
  CONTEXT_HASH_OUTPUT=$(shasum -a 256 -- "$CONTEXT_ARCHIVE" 2>/dev/null) || \
    die 'cannot hash the controller source snapshot'
elif command -v sha256sum >/dev/null 2>&1; then
  CONTEXT_HASH_OUTPUT=$(sha256sum -- "$CONTEXT_ARCHIVE" 2>/dev/null) || \
    die 'cannot hash the controller source snapshot'
else
  die 'neither shasum nor sha256sum is available'
fi
CONTEXT_HASH=${CONTEXT_HASH_OUTPUT%%[[:space:]]*}
[[ "$CONTEXT_HASH" =~ ^[0-9a-f]{64}$ ]] || die 'controller source snapshot digest is malformed'
SOURCE_SNAPSHOT_DIGEST=sha256:$CONTEXT_HASH

tar -xf "$CONTEXT_ARCHIVE" -C "$CONTEXT_ROOT" || \
  die 'cannot materialize the controller context snapshot'
for REQUIRED_SOURCE_FILE in \
  .dockerignore \
  deploy/container/Dockerfile \
  package.json \
  package-lock.json; do
  CONTEXT_FILE=$CONTEXT_ROOT/$REQUIRED_SOURCE_FILE
  [[ -f "$CONTEXT_FILE" && ! -L "$CONTEXT_FILE" && -r "$CONTEXT_FILE" ]] || \
    die "required file is unavailable in the context snapshot: $REQUIRED_SOURCE_FILE"
done

# A clean source is built from its immutable commit archive. Rechecking both
# repositories still catches a checkout or edit that occurred during snapshot
# preparation instead of silently relaxing the clean-tree contract.
resolve_revision "$SOURCE_ROOT" 'Forge v4 source'
[[ "$RESOLVED_REVISION" == "$SOURCE_REVISION" ]] || \
  die 'Forge v4 source HEAD changed while preparing the build'
resolve_dirty_state "$SOURCE_ROOT" 'Forge v4 source'
[[ "$RESOLVED_DIRTY" == "$SOURCE_DIRTY" ]] || \
  die 'Forge v4 source state changed while preparing the build'
resolve_revision "$BUILDER_ROOT" 'Pixel companion repository'
[[ "$RESOLVED_REVISION" == "$BUILDER_REVISION" ]] || \
  die 'Pixel companion HEAD changed while preparing the build'
resolve_dirty_state "$BUILDER_ROOT" 'Pixel companion repository'
[[ "$RESOLVED_DIRTY" == "$BUILDER_DIRTY" ]] || \
  die 'Pixel companion state changed while preparing the build'

# Allocate and write a same-directory probe before Docker can replace the
# stable tag. The completed file is later published with link(1), whose exact
# two-path interface provides atomic no-replace behavior.
MANIFEST_TEMP=$(mktemp "$MANIFEST_PARENT/.${MANIFEST_NAME}.tmp.XXXXXX") || \
  die 'cannot create manifest temporary file'
chmod 600 "$MANIFEST_TEMP" || die 'cannot protect manifest temporary file'
printf '%4096s' '' > "$MANIFEST_TEMP" || die 'cannot write manifest temporary file'
MANIFEST_LINK_PROBE=$MANIFEST_TEMP.link
link "$MANIFEST_TEMP" "$MANIFEST_LINK_PROBE" 2>/dev/null || \
  die 'manifest filesystem does not support safe publication'
rm -f -- "$MANIFEST_LINK_PROBE" || die 'cannot remove manifest publication probe'
MANIFEST_LINK_PROBE=

if ! docker build \
  --platform "linux/$PLATFORM_ARCH" \
  --build-arg "EIP_CVE_UID=$CONTROLLER_UID" \
  --build-arg "EIP_CVE_GID=$CONTROLLER_GID" \
  --label "org.opencontainers.image.source=https://github.com/exploitintel/eip-pixel8a-forge" \
  --label "org.opencontainers.image.revision=$SOURCE_REVISION" \
  --label "io.exploitintel.build.source-dirty=$SOURCE_DIRTY_LABEL" \
  --label "io.exploitintel.build.builder-revision=$BUILDER_REVISION" \
  --label "io.exploitintel.build.builder-dirty=$BUILDER_DIRTY_LABEL" \
  --label "io.exploitintel.build.source-snapshot-sha256=$SOURCE_SNAPSHOT_DIGEST" \
  --file "$CONTEXT_ROOT/deploy/container/Dockerfile" \
  --target controller \
  --tag "$CONTROLLER_TAG" \
  "$CONTEXT_ROOT"; then
  die 'controller image build failed'
fi

INSPECT_FORMAT='{{.Id}}|{{.Architecture}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{index .Config.Labels "io.exploitintel.build.source-dirty"}}|{{index .Config.Labels "io.exploitintel.build.builder-revision"}}|{{index .Config.Labels "io.exploitintel.build.builder-dirty"}}|{{index .Config.Labels "io.exploitintel.build.source-snapshot-sha256"}}'
INSPECT_OUTPUT=$(docker image inspect --format "$INSPECT_FORMAT" "$CONTROLLER_TAG") || \
  die 'cannot inspect the built controller image'
[[ "$INSPECT_OUTPUT" != *$'\n'* && "$INSPECT_OUTPUT" != *$'\r'* ]] || \
  die 'controller image inspection returned malformed output'

IFS='|' read -r LOCAL_IMAGE_ID IMAGE_ARCH INSPECT_SOURCE_REVISION \
  INSPECT_SOURCE_DIRTY INSPECT_BUILDER_REVISION INSPECT_BUILDER_DIRTY \
  INSPECT_SOURCE_SNAPSHOT_DIGEST INSPECT_EXTRA \
  <<< "$INSPECT_OUTPUT"
EXPECTED_INSPECT_OUTPUT=$LOCAL_IMAGE_ID'|'$IMAGE_ARCH'|'$INSPECT_SOURCE_REVISION'|'$INSPECT_SOURCE_DIRTY'|'$INSPECT_BUILDER_REVISION'|'$INSPECT_BUILDER_DIRTY'|'$INSPECT_SOURCE_SNAPSHOT_DIGEST
[[ -z "$INSPECT_EXTRA" && "$INSPECT_OUTPUT" == "$EXPECTED_INSPECT_OUTPUT" ]] || \
  die 'controller image inspection returned malformed fields'
[[ "$LOCAL_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'controller image ID is malformed'
[[ "$IMAGE_ARCH" == arm64 ]] || die 'controller image architecture is not arm64'
[[ "$INSPECT_SOURCE_REVISION" == "$SOURCE_REVISION" ]] || \
  die 'controller image source revision label does not match'
[[ "$INSPECT_SOURCE_DIRTY" == "$SOURCE_DIRTY_LABEL" ]] || \
  die 'controller image source dirty label does not match'
[[ "$INSPECT_BUILDER_REVISION" == "$BUILDER_REVISION" ]] || \
  die 'controller image builder revision label does not match'
[[ "$INSPECT_BUILDER_DIRTY" == "$BUILDER_DIRTY_LABEL" ]] || \
  die 'controller image builder dirty label does not match'
[[ "$INSPECT_SOURCE_SNAPSHOT_DIGEST" == "$SOURCE_SNAPSHOT_DIGEST" ]] || \
  die 'controller image source snapshot digest label does not match'

# Docker Desktop's containerd store identifies an attested image by its OCI
# index, while a Docker archive imported on Android identifies the same image
# by its config digest. Record the portable post-import identity used by the
# phone deployment transaction.
CONTROLLER_CONFIG_PATH=$(docker image save "$CONTROLLER_TAG" | tar -xOf - manifest.json | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const manifest = JSON.parse(input);
  const entries = manifest.filter(entry =>
    Array.isArray(entry.RepoTags) && entry.RepoTags.includes("eip-cve-controller:phone"));
  if (entries.length !== 1 ||
      !/^blobs\/sha256\/[0-9a-f]{64}$/.test(String(entries[0].Config || ""))) process.exit(2);
  process.stdout.write(entries[0].Config);
});
') || die 'cannot resolve the controller config digest from its Docker archive'
IMAGE_ID=sha256:${CONTROLLER_CONFIG_PATH##*/}

CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || die 'cannot obtain manifest timestamp'
[[ "$CREATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
  die 'manifest timestamp is malformed'

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "kind": "eip-controller-build-manifest",\n'
  printf '  "createdAt": "%s",\n' "$CREATED_AT"
  printf '  "provenanceLevel": "source-attributed",\n'
  printf '  "scope": "controller-only",\n'
  printf '  "platform": "linux/arm64",\n'
  printf '  "builder": {\n'
  printf '    "revision": "%s",\n' "$BUILDER_REVISION"
  printf '    "dirty": %s\n' "$BUILDER_DIRTY"
  printf '  },\n'
  printf '  "controller": {\n'
  printf '    "tag": "%s",\n' "$CONTROLLER_TAG"
  printf '    "imageId": "%s",\n' "$IMAGE_ID"
  printf '    "sourceRevision": "%s",\n' "$SOURCE_REVISION"
  printf '    "sourceDirty": %s,\n' "$SOURCE_DIRTY"
  printf '    "sourceSnapshotDigest": "%s",\n' "$SOURCE_SNAPSHOT_DIGEST"
  printf '    "dockerfile": "deploy/container/Dockerfile",\n'
  printf '    "target": "controller",\n'
  printf '    "uid": %s,\n' "$CONTROLLER_UID"
  printf '    "gid": %s\n' "$CONTROLLER_GID"
  printf '  }\n'
  printf '}\n'
} > "$MANIFEST_TEMP"
chmod 600 "$MANIFEST_TEMP" || die 'cannot protect build manifest'

link "$MANIFEST_TEMP" "$MANIFEST_PATH" 2>/dev/null || \
  die 'manifest output appeared during the build; refusing to replace it'
[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" && "$MANIFEST_PATH" -ef "$MANIFEST_TEMP" ]] || \
  die 'manifest publication postcondition failed'
rm -f -- "$MANIFEST_TEMP" || die 'cannot remove manifest publication link'
MANIFEST_TEMP=
rm -rf -- "$CONTEXT_WORK_ROOT" || die 'cannot remove controller context workspace'
CONTEXT_WORK_ROOT=
trap - EXIT HUP INT TERM

if [[ "$SOURCE_DIRTY" == true || "$BUILDER_DIRTY" == true ]]; then
  printf '%s\n' 'warning: manifest records dirty source; commit IDs are base revisions, not exact reconstruction' >&2
fi
printf 'built %s as %s\n' "$CONTROLLER_TAG" "$IMAGE_ID"
printf 'wrote source-attribution manifest: %s\n' "$MANIFEST_PATH"
