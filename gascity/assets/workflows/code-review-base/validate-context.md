This is the `code-review-base` methodology contract context validation step.

Concrete methodology packs override this step when their review needs extra
inputs. Validate `{{subject_path}}`, `{{report_path}}`, and optional
`{{context_path}}` before any reviewer writes a report. Validate
`{{interaction_mode}}` is `interactive`, `autonomous`, or `headless` and
`{{review_mode}}` is `report`, `agent`, or `interactive`; stop blocked with a
machine-readable `gc.blocked_reason` on unknown values.
