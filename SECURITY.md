# Security policy

## Private reporting

Use [GitHub Private Vulnerability Reporting](https://github.com/olgvroe/Vecta/security/advisories/new)
for this repository. At public launch, the maintainer must enable the form and
verify that **Security → Advisories → Report a vulnerability** is available before
releasing binary assets. The form is not assumed to work during private staging.

If it is unavailable, do not post sensitive details publicly. Contact the
maintainer through an already trusted private channel, or make a non-sensitive
request to enable private reporting. No separate email inbox is advertised.

GitHub instructions:
https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository

## What to report

For the 0.1.x developer preview, include version/build, macOS/architecture,
reproduction steps using synthetic input, impact and a proposed mitigation if
known. Never attach recordings, transcripts, summaries, voice embeddings, user
documents, serial/device-owner identities, Partner secrets/tokens, authorization
files, Keychain exports, databases, local logs or private diagnostic archives to
public issues. Redact identifying paths and identifiers in private reports too.
Do not test on other people's hardware or modify/delete real recordings.

The owner must nominate a responder and monitoring process before public launch.
A suggested response target is acknowledgement within 7 days, followed by triage,
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
Cached valid identity reconnect stays local; see README for the network boundaries.
Credentials/identities belong in Keychain; temporary tokens are memory-only.

Imports/migrations must preserve originals and validate paths, file types,
ownership/hashes, cancellation and output identity. Exports may share personal
data only through an explicit user-selected destination. Build/export tooling
uses an explicit public allowlist, rejects private assets/secrets/absolute home
paths and never archives the whole working directory. These technical gates are
not a formal security proof or a guarantee of no unknown secret/vulnerability.

Ad-hoc signing is integrity evidence, not Developer ID/notarization or a security
endorsement. Never disable macOS protections to install a candidate.
