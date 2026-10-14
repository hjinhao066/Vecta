# Security policy

## Private reporting — owner activation required

**Before public launch, the owner must establish and test a private vulnerability-
reporting route.** GitHub documents Private Vulnerability Reporting for public
repositories: repository Settings > Advanced Security > Private vulnerability
reporting > Enable. Verify externally that Security > Advisories exposes **Report
a vulnerability** before announcing the launch or distributing release assets.
Do not claim this form works while the staging repository is private. If it is
unavailable during the visibility transition, first designate and verify an
owner-controlled private contact, then enable and verify the GitHub form once the
repository is public. Report privately through the verified route; do not create
a public issue containing exploit details.

This local source tree has no public GitHub repository/contact configured, so the
private form is **not currently verified/available**. This is an explicit public-
release blocker, not a claim that a private reporting service already exists.
If the button is missing, do not send sensitive details: contact the owner through
an already trusted private channel, or open a non-sensitive request asking them
to enable private reporting. A controlled private email address can be substituted
only after the owner chooses and verifies it; no placeholder inbox is advertised.
GitHub instructions: https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository

## What to report

For the upcoming0.1.x developer preview, include version/build, macOS/architecture,
reproduction steps using synthetic input, impact and a proposed mitigation if
known. Never attach recordings, transcripts, summaries, voice embeddings, user
documents, serial/device-owner identities, Partner secrets/tokens, authorization
files, Keychain exports, databases, local logs or private diagnostic archives to
public issues. Redact identifying paths and identifiers in private reports too.
Do not test on other people's hardware or modify/delete real recordings.

The owner must nominate a responder and monitoring process before public launch.
A suggested response target is acknowledgement within7 days, followed by triage,
coordinated disclosure and a security advisory when appropriate. This is a proposed
process, not an already staffed SLA. Only the current preview is tested; old
predecessor apps, arbitrary firmware and unsupported platforms are outside this
repository's acceptance scope.

## Privacy boundaries

Inference is local-only: actual Speech/MLX worker launches use deny-network policy.
The main native app is not claimed to be App-Sandbox-entitled; it uses macOS
Bluetooth/location/local-network permissions, filesystem controls and bookmarks.
No hosted inference fallback exists. User-triggered model downloads and initial
PLAUD Partner authorization are separate network operations, not inference leaks.
Initial provisioning exchanges credential/access-token metadata, obtains an RSA
key pair from the Partner service, and sends device type/serial for a signature.
Cached valid identity reconnect stays local; see README for the precise table.
Credentials/identities belong in Keychain; temporary tokens are memory-only.

Imports/migrations must preserve originals and validate paths, file types,
ownership/hashes, cancellation and output identity. Exports may share personal
data only through an explicit user-selected destination. Build/export tooling
uses an explicit public allowlist, rejects private assets/secrets/absolute home
paths and never archives the whole working directory. These technical gates are
not a formal security proof or a guarantee of no unknown secret/vulnerability.

Ad-hoc signing is integrity evidence, not Developer ID/notarization or a security
endorsement. Never disable macOS protections to install a candidate.
