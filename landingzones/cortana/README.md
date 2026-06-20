# Cortana

Cortana is a Hermes Agent based personal assistant landing zone.

The initial project shape is intentionally disabled in `.config/lab/apps.yaml`
until namespace-scoped secrets and external integration choices are ready.

## Personae

- Personal assistant: mail monitoring, calendar activity creation, Todoist task capture, daily briefings, Sunday week-ahead briefings, electricity price windows, and bank holiday awareness.
- Technical writer: technical documents, implementation plans, runbooks, release notes, and user-facing explanations.

## Voice

Cortana is configured for Discord voice with local speech-to-text and Edge
text-to-speech:

- `config.stt.enabled: true`
- `config.stt.provider: local`
- `config.tts.provider: edge`
- `config.voice.auto_tts: true`
- `config.voice.listen: true`

## Before enabling

Create sealed secrets for the `cortana` namespace:

- `cortana-openai-api-key`
- `cortana-discord-token`
- `cortana-todoist-api-token`, when Todoist tooling is selected

Then set `cortana.enabled: true` in `.config/lab/apps.yaml`.
