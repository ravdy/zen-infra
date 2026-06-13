#!/usr/bin/env python3
# =============================================================================
# ECR Image Cleanup
#
# Deletes images older than 6 months (default) from all pharma ECR repositories.
# Skips images tagged "latest" and any user-specified protected tags.
#
# Requirements: pip install boto3
#
# Usage:
#   # Preview what would be deleted (safe - makes no changes)
#   python3 05_cleanup_ecr_images.py --dry-run
#
#   # Delete images older than 6 months
#   python3 05_cleanup_ecr_images.py
#
#   # Target a specific repo only
#   python3 05_cleanup_ecr_images.py --repos api-gateway auth-service
#
#   # Change the age threshold (e.g. 3 months)
#   python3 05_cleanup_ecr_images.py --months 3
#
#   # Override region
#   python3 05_cleanup_ecr_images.py --region us-west-2
#
#   # Protect additional tags from deletion (space-separated)
#   python3 05_cleanup_ecr_images.py --protect-tags stable release
# =============================================================================

import argparse
import sys
from datetime import datetime, timezone, timedelta

try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError, NoRegionError
except ImportError:
    print("ERROR: boto3 is not installed. Run: pip install boto3", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging helpers (consistent with the other scripts in this repo)
# ---------------------------------------------------------------------------
RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
NC     = "\033[0m"

def _ts():
    return datetime.now().strftime("%H:%M:%S")

def log(msg):   print(f"{GREEN}[{_ts()}] OK  {msg}{NC}")
def warn(msg):  print(f"{YELLOW}[{_ts()}] !!  {msg}{NC}")
def info(msg):  print(f"{CYAN}[{_ts()}]    {msg}{NC}")
def die(msg):
    print(f"{RED}[{_ts()}] ERR {msg}{NC}", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# All ECR repositories created by Terraform for this project
# (matches the `repositories` list in envs/*/main.tf)
# ---------------------------------------------------------------------------
PHARMA_REPOS = [
    "api-gateway",
    "auth-service",
    "drug-catalog-service",
    "inventory-service",
    "manufacturing-service",
    "notification-service",
    "pharma-ui",
    "supplier-service",
    "qc-service",
]

# ---------------------------------------------------------------------------
# ECR batch_delete_image accepts at most 100 image IDs per call
# ---------------------------------------------------------------------------
_ECR_BATCH_DELETE_LIMIT = 100


def parse_args():
    parser = argparse.ArgumentParser(
        description="Delete ECR images older than N months from pharma repositories.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be deleted without actually deleting anything.",
    )
    parser.add_argument(
        "--months", type=int, default=6,
        help="Delete images older than this many months (default: 6).",
    )
    parser.add_argument(
        "--region", default=None,
        help="AWS region (defaults to AWS_DEFAULT_REGION / boto3 config).",
    )
    parser.add_argument(
        "--repos", nargs="+", default=None,
        metavar="REPO",
        help="Limit cleanup to these repository names (default: all pharma repos).",
    )
    parser.add_argument(
        "--protect-tags", nargs="+", default=[],
        metavar="TAG",
        help="Extra image tags to never delete (e.g. stable release). "
             "'latest' is always protected.",
    )
    return parser.parse_args()


def list_all_images(ecr, repository_name):
    """Return every image detail object in the repository (handles pagination)."""
    images = []
    paginator = ecr.get_paginator("describe_images")
    for page in paginator.paginate(repositoryName=repository_name):
        images.extend(page.get("imageDetails", []))
    return images


def is_protected(image, protected_tags):
    """Return True if the image carries any tag that must not be deleted."""
    tags = image.get("imageTags", [])
    return bool(set(tags) & protected_tags)


def image_label(image):
    """Human-readable label: tag list or digest prefix."""
    tags = image.get("imageTags")
    if tags:
        return ", ".join(sorted(tags))
    digest = image.get("imageDigest", "unknown")
    return f"<untagged> {digest[:19]}..."


def delete_images_in_batches(ecr, repository_name, image_ids, dry_run):
    """
    Delete a list of imageIds from a repository in chunks of 100.
    Returns (deleted_count, failed_count).
    """
    deleted = 0
    failed  = 0

    for i in range(0, len(image_ids), _ECR_BATCH_DELETE_LIMIT):
        chunk = image_ids[i : i + _ECR_BATCH_DELETE_LIMIT]

        if dry_run:
            deleted += len(chunk)
            continue

        try:
            response = ecr.batch_delete_image(
                repositoryName=repository_name,
                imageIds=chunk,
            )
            deleted += len(response.get("imageIds", []))
            for failure in response.get("failures", []):
                warn(f"  Delete failed for {failure.get('imageId')}: "
                     f"{failure.get('failureReason')}")
                failed += 1
        except ClientError as exc:
            warn(f"  batch_delete_image error: {exc}")
            failed += len(chunk)

    return deleted, failed


def process_repository(ecr, repo_name, cutoff, protected_tags, dry_run):
    """
    Inspect one ECR repository, identify stale images, and delete them.
    Returns (scanned, deleted, failed, skipped).
    """
    try:
        images = list_all_images(ecr, repo_name)
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "RepositoryNotFoundException":
            warn(f"  Repository '{repo_name}' not found — skipping.")
        else:
            warn(f"  Could not list images in '{repo_name}': {exc}")
        return 0, 0, 0, 0

    stale_ids   = []
    skipped     = 0

    for image in images:
        pushed_at = image.get("imagePushedAt")
        if pushed_at is None:
            continue

        # boto3 returns a timezone-aware datetime
        if pushed_at.tzinfo is None:
            pushed_at = pushed_at.replace(tzinfo=timezone.utc)

        if pushed_at >= cutoff:
            continue  # image is recent — leave it alone

        if is_protected(image, protected_tags):
            skipped += 1
            info(f"  SKIP  [{repo_name}] {image_label(image)}  "
                 f"(pushed {pushed_at.date()}, protected tag)")
            continue

        action = "WOULD DELETE" if dry_run else "DELETE"
        print(f"  {YELLOW}{action}{NC}  [{repo_name}] {image_label(image)}  "
              f"(pushed {pushed_at.date()})")

        # Prefer imageDigest for the deletion key to avoid tag-alias confusion
        if "imageDigest" in image:
            stale_ids.append({"imageDigest": image["imageDigest"]})
        else:
            # Untagged images sometimes lack a digest in describe_images; use tag
            for tag in image.get("imageTags", []):
                stale_ids.append({"imageTag": tag})

    if not stale_ids:
        return len(images), 0, 0, skipped

    deleted, failed = delete_images_in_batches(ecr, repo_name, stale_ids, dry_run)
    return len(images), deleted, failed, skipped


def main():
    args = parse_args()

    protected_tags = {"latest"} | set(args.protect_tags)
    repos          = args.repos or PHARMA_REPOS
    cutoff         = datetime.now(tz=timezone.utc) - timedelta(days=args.months * 30)

    # -------------------------------------------------------------------------
    # Print run configuration
    # -------------------------------------------------------------------------
    print()
    print("============================================")
    print("  Zen Pharma -- ECR Image Cleanup")
    print("============================================")
    print()
    print(f"  Mode           : {'DRY RUN (no changes will be made)' if args.dry_run else 'LIVE (images will be deleted)'}")
    print(f"  Age threshold  : {args.months} months  (before {cutoff.date()})")
    print(f"  Protected tags : {', '.join(sorted(protected_tags))}")
    print(f"  Repositories   : {', '.join(repos)}")
    print()

    if not args.dry_run:
        confirm = input("  Proceed with deletion? [y/N]: ").strip().lower()
        if confirm != "y":
            print("  Aborted.")
            sys.exit(0)
        print()

    # -------------------------------------------------------------------------
    # Build boto3 ECR client
    # -------------------------------------------------------------------------
    try:
        session = boto3.Session(region_name=args.region)
        ecr     = session.client("ecr")
        # Quick credential check
        ecr.describe_registry()
    except NoCredentialsError:
        die("No AWS credentials found. Configure via environment variables, "
            "~/.aws/credentials, or an IAM role.")
    except NoRegionError:
        die("No AWS region specified. Use --region or set AWS_DEFAULT_REGION.")
    except ClientError as exc:
        die(f"AWS error: {exc}")

    # -------------------------------------------------------------------------
    # Process each repository
    # -------------------------------------------------------------------------
    total_scanned = 0
    total_deleted = 0
    total_failed  = 0
    total_skipped = 0

    for repo in repos:
        print(f"--------------------------------------------")
        print(f"  Repository: {repo}")
        print(f"--------------------------------------------")

        scanned, deleted, failed, skipped = process_repository(
            ecr, repo, cutoff, protected_tags, args.dry_run,
        )

        total_scanned += scanned
        total_deleted += deleted
        total_failed  += failed
        total_skipped += skipped

        if deleted == 0 and skipped == 0:
            log(f"  No stale images in '{repo}'.")
        else:
            verb = "Would delete" if args.dry_run else "Deleted"
            log(f"  {verb} {deleted} image(s) | skipped {skipped} protected | "
                f"failed {failed} | total in repo {scanned}")
        print()

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    print("============================================")
    print("  Summary")
    print("============================================")
    print(f"  Repositories processed : {len(repos)}")
    print(f"  Images scanned         : {total_scanned}")
    verb = "Would be deleted" if args.dry_run else "Deleted"
    print(f"  {verb:<24} : {total_deleted}")
    print(f"  Skipped (protected)    : {total_skipped}")
    if total_failed:
        warn(f"  Failed deletions       : {total_failed}")
    if args.dry_run:
        print()
        print(f"  {CYAN}Re-run without --dry-run to apply the deletions.{NC}")
    print("============================================")
    print()

    sys.exit(1 if total_failed else 0)


if __name__ == "__main__":
    main()
