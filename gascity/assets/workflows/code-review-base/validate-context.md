This is the `code-review-base` methodology contract context validation step.

Concrete methodology packs override this step when their review needs extra
inputs. Validate `{{subject_path}}`, `{{report_path}}`, and optional
`{{context_path}}` before any reviewer writes a report.
