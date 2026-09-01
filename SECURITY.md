# Security

BrowserCaptureKit operates inside authenticated browser sessions. Treat every
capture as sensitive and every page as hostile.

## Invariants

- The host authorizes actions; page content and models cannot authorize them.
- Actions are bound to the retained browser session, page epoch, and snapshot.
- Stale, ambiguous, obscured, disabled, or non-editable targets fail closed.
- Credential, MFA, CAPTCHA, passkey, payment, and permission steps require the user.
- Post-dispatch acknowledgement loss is uncertain and must not be auto-retried.
- Cross-origin transport replay requires an explicit vendor and destination binding.
- Model-facing exports use redaction and application-owned retention controls.

## Sensitive data

Raw events may include cookies, web storage, headers, request/response bodies,
console messages, URLs, and editable values. `BrowserRedactionPolicy.safeForModel`
removes common secrets and bodies, but the host must additionally enforce
purpose limitation, retention, deletion, access control, and domain-specific PII
handling.

## Reporting

This is a private repository. Report vulnerabilities directly to the repository
owner and do not include live credentials or unredacted customer data.
