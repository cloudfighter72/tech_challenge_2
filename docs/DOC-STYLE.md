# Markdown house style

Rules every `.md` file in this repo follows, so markdownlint stays quiet.

- Blank line before and after every fenced code block.
- Every opening fence has a language: `bash`, `hcl`, `yaml`, `text`, `json`.
- Blank line before and after every list.
- Ordered lists numbered sequentially: 1, 2, 3.
- Table separators spaced: `| --- | --- |`, never `|---|---|`.
- URLs are wrapped in backticks or written as `[text](url)`, never bare.
- One `#` heading per file, at the top.

Check before committing:

```bash
python3 docs/mdcheck.py README.md PLAN.md
```

`.markdownlint.json` disables three rules that fight normal README writing: MD013 line
length, MD033 inline HTML, MD041 first-line heading.
