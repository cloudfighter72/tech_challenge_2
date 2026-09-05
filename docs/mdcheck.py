"""Strict read-only markdownlint subset. Reports, never edits."""
import re, sys, pathlib
FENCE = re.compile(r'^(\s*)(`{3,}|~{3,})(.*)$')
LIST  = re.compile(r'^(\s*)([-*+]|\d+[.)])\s+\S')
OL    = re.compile(r'^(\s*)(\d+)[.)]\s+\S')
SEP   = re.compile(r'^\s*\|(?:\s*:?-{2,}:?\s*\|)+\s*$')
BARE  = re.compile(r'(?<![(<`\[/\w])https?://')

def lint(path):
    lines = pathlib.Path(path).read_text().split('\n')
    issues=[]; in_fence=False; marker=None; ol_stack={}
    for i,ln in enumerate(lines):
        n=i+1
        prev = lines[i-1] if i else ''
        nxt  = lines[i+1] if i+1<len(lines) else ''
        m = FENCE.match(ln)
        if m and not in_fence:
            in_fence, marker = True, m.group(2)[0]
            if not m.group(3).strip(): issues.append((n,'MD040 no language'))
            if i and prev.strip():     issues.append((n,'MD031 no blank before fence'))
            continue
        if m and in_fence and m.group(2)[0]==marker and not m.group(3).strip():
            in_fence=False
            if nxt.strip():            issues.append((n,'MD031 no blank after fence'))
            continue
        if in_fence: continue
        stripped = re.sub(r'`[^`]*`', '', ln)          # ignore inline code spans
        stripped = re.sub(r'\[[^\]]*\]\([^)]*\)', '', stripped)  # and md links
        if BARE.search(stripped):      issues.append((n,'MD034 bare url'))
        if SEP.match(ln) and not ln.strip().startswith('| ---'):
            issues.append((n,'MD060 compact separator'))
        if LIST.match(ln):
            if i and prev.strip() and not LIST.match(prev) \
               and not prev.startswith((' ','\t','|','>')):
                issues.append((n,'MD032 no blank before list'))
            om = OL.match(ln)
            if om:
                ind=len(om.group(1)); num=int(om.group(2))
                exp = ol_stack.get(ind,0)+1
                if not (num==exp or num==1):
                    issues.append((n,f'MD029 ordered prefix {num}, expected {exp}'))
                ol_stack[ind]= 1 if num==1 else num
        elif not ln.startswith((' ','\t')) and ln.strip():
            ol_stack={}
    return issues

ok=True
for f in sys.argv[1:]:
    iss = lint(f)
    print(f"{f}: {'CLEAN' if not iss else ''}")
    for n,msg in iss: print(f"   line {n}: {msg}"); ok=False
sys.exit(0 if ok else 1)
