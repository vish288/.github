# Security Policy

## Reporting a vulnerability

Report privately through **GitHub's private vulnerability reporting** on the
affected repository: open its **Security** tab and choose **Report a
vulnerability**. This reaches the maintainer directly and keeps the report
confidential until a fix ships. Please do not open a public issue for a
security problem.

Include the affected version, how to reproduce it, and the impact as you see
it. Expect an acknowledgement within a few days.

## Supported versions

Only the latest released minor of each server receives security fixes. Upgrade
to the current release before reporting.

## Disclosure

We aim to ship a fix and publish an advisory within **90 days** of a valid
report, and will coordinate the disclosure date with you.

## What the servers send

These MCP servers talk only to the upstream API you configure (GitLab, Argo CD,
Coda, Atlassian). They send no telemetry, phone home to no other host, and mint
no credential from a client token. Your token stays between the server and that
one upstream.
