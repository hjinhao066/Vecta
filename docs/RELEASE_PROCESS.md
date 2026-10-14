# Owner release procedure — nothing is published by local tooling

## Local preparation

Run the one-command clean source release pipeline in BUILD.md. Review actual
verification-summary/artifact-verification, matching source/kit identities, native
checks and RELEASE_READINESS_REPORT.md. Do not distribute frontend/development
fixtures, logs, installed-app backups, credentials, recordings or model weights.
Release assets are the DMG, SHA256SUMS, source archive, LAME source/object/relink kit,
component-license archive and release notes. Never omit the matching LAME kit.

## Repository owner actions (not performed by an agent)

1. Inspect the exact public export and Git index/history. Main license is already
   Apache-2.0; preserve LICENSE/NOTICE and provenance. Do not publish the working
   directory/private .build history wholesale.
2. Create the intended repository only after explicit owner publication approval.
   Main line: main; development: develop. Configure the remote/visibility yourself.
3. Set a verified private security/community-reporting contact and responder before
   public launch. GitHub documents Private Vulnerability Reporting for public repos;
   do not assume the form is available while staging privately. When the repository
   becomes public, enable it and test Security > Report a vulnerability before
   announcing the launch or distributing binaries. Keep the verified private
   contact available during that transition; see SECURITY.md.
4. Protect main/develop and version tags; require source-security, model-free and
   full-build checks. Review required check names after their first actual cloud run.
5. Create a `release-preparation` environment with required owner reviewers,
   disallow self-approval where supported, and restrict deployment refs. Configure
   it BEFORE enabling tag workflows; merely naming it in YAML does not enable
   review protection. Actions environment/branch controls are not verified locally.
6. Run macOS CI on GitHub and review runner/toolchain compatibility and quotas.
   Standard macos-15 is ARM64, with7 GB RAM; no large models are downloaded in CI.
7. Perform clean-user downloaded/quarantined DMG first launch, no-model/no-credential
   onboarding, permissions and migration acceptance on a compatible Mac. Reconfirm
   hardware/model/long-recording acceptance where the intended support claim needs it.

## Tag / manual preparation workflow

`release.yml` handles version tags and manual dispatch. It has read-only repository
permissions, performs a fresh public-source build/tests/binary/DMG/relink check,
and prepares versioned notes/checksums/license/source/relink assets. Tags do NOT
upload source assets. Manual dispatch defaults `upload_artifacts=false`; an owner
can explicitly opt into GitHub Actions artifact upload behind the protected
`release-preparation` environment. Artifacts are temporary workflow assets, not a
public GitHub Release. No public-release/push/publish command exists in this workflow.

A local run of Tools/release.py clean exercises the same release commands without
GitHub upload, credentials or publication. Local YAML/contract/actionlint checks
are not proof of a GitHub-hosted run or actual environment protection.

## Public publication remains a separate owner decision

Only after separate explicit owner authorization, verify the intended version/tag,
artifact SHA256, source revision, notes/acceptance limits and matching LAME kit.
Then the owner may create/upload a GitHub Release using the website or their own
chosen process. Developer ID/notarization is NOT required for this ad-hoc preview,
but it must be clearly disclosed. The current workflow deliberately cannot silently
publish a public release or turn a tag into consent to publication.
