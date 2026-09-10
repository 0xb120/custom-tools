#!/usr/bin/env bash
# PostToolUse(Write|Edit) hook — enforce the report-formatting rules from
# AGENTS.md (§ Report formatting) on report files:
#   1. Prose is copy-paste-ready: never hard-wrapped mid-sentence. One paragraph
#      = one continuous line; the renderer wraps it. Hard newlines belong only
#      between block elements.
#   2. Every fenced code block opens with a language (```sh, ```http, ```json).
#   3. Nothing is ever indented, except a nested list item — which is indented
#      with spaces, never a tab. Everything else (fences, prose, tables) starts
#      at column 0, including the content that belongs to a list item: an
#      indented fence turns into an indented-code block or nests inside the
#      surrounding list, which breaks copy-paste and the report renderer.
#
# Scope: *.md under findings/ and the root-level <activity>.md (identified by
# its db:render markers, not by name). Working files — journal.md, TODO.md,
# AGENTS.md, the _template.md / finding.md reference — are exempt.
#
# Detection: a "hard-wrapped paragraph" is a run of 2+ consecutive lines that
# are all flowing prose — i.e. with no blank line, heading, list marker, table
# row, blockquote, code fence, horizontal rule, HTML/marker line, or `Label:` /
# `**Label**:` definition line breaking them apart. That run IS the violation.
# A fence violation is an *opening* fence whose info string is empty (the closing
# fence never carries a language). An indentation violation is any line with
# leading whitespace that is not a list item (`- `, `* `, `+ `, `1. `, `1) `), or
# a list item whose indentation contains a tab. Inside a fenced block every line
# is payload and is left alone, and an HTML comment block is skipped whole — the
# reference comments `ptctl.py finding create` copies into every write-up are
# multi-line and are not report prose.
#
# Exit 2 with the offending line numbers so Claude fixes the file. Exit 0 when
# the file is clean or out of scope.

INPUT="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

file="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

case "$file" in
    *.md) ;;
    *) exit 0 ;;
esac

# Never lint the untouched reference templates.
case "$file" in
    */_template.md|*/finding.md) exit 0 ;;
esac

# In scope only for report prose: a file under findings/, or the root
# <activity>.md (the only .md carrying the db:render markers).
in_scope=0
case "$file" in
    */findings/*.md|findings/*.md) in_scope=1 ;;
esac
if [ "$in_scope" -eq 0 ] && grep -qF '<!-- db:render' "$file" 2>/dev/null; then
    in_scope=1
fi
[ "$in_scope" -eq 0 ] && exit 0

# One pass, three classes of violation, tagged so the report explains each.
report="$(awk '
function flush(){ if (count >= 2) printf "wrap\t  lines %d-%d\n", start, last; count=0; start=0; last=0 }
BEGIN { incode=0; incomment=0 }
{
    if ($0 ~ /^[[:space:]]*```/ && !incomment) {                                   # code fence
        flush()
        if ($0 ~ /^[[:space:]]/)
            printf "indent\t  line %d: indented code fence\n", NR
        if (!incode) {
            info = $0
            sub(/^[[:space:]]*`+/, "", info)
            sub(/[[:space:]]+$/, "", info)
            if (info == "")
                printf "fence\t  line %d: code fence without a language\n", NR
        }
        incode = !incode
        next
    }
    if (incode)                                                  { next }
    if (incomment)                                               { if ($0 ~ /-->/) incomment=0; next }  # in html comment
    if ($0 ~ /^[[:space:]]*<!--/) { flush(); if ($0 !~ /-->/) incomment=1; next }      # html comment / marker
    if ($0 ~ /^[[:space:]]*$/)                                   { flush(); next }  # blank
    if ($0 ~ /^[ \t]/) {                                                               # indentation
        if ($0 ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/) {                                   # nested list item
            if ($0 ~ /^[ ]*\t/) printf "indent\t  line %d: tab-indented list item\n", NR
        } else {
            printf "indent\t  line %d: indented line\n", NR
        }
    }
    if ($0 ~ /^[[:space:]]*#/)                                   { flush(); next }  # heading
    if ($0 ~ /^[[:space:]]*[-*+][[:space:]]/)                    { flush(); next }  # bullet
    if ($0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/)               { flush(); next }  # numbered
    if ($0 ~ /^[[:space:]]*>/)                                   { flush(); next }  # blockquote
    if (index($0, "|") > 0)                                      { flush(); next }  # table row
    if ($0 ~ /-->[[:space:]]*$/)                                 { flush(); next }  # marker tail
    if ($0 ~ /^[[:space:]]*(-{3,}|={3,})[[:space:]]*$/)          { flush(); next }  # horizontal rule
    if ($0 ~ /^[[:space:]]*\*{0,2}[A-Za-z][A-Za-z0-9 _\/()-]*\*{0,2}:[[:space:]]/) { flush(); next }  # Label: value
    if (start == 0) start = NR
    count++; last = NR
}
END { flush() }
' "$file")"

[ -z "$report" ] && exit 0

wrapped="$(printf '%s\n' "$report" | awk -F'\t' '$1=="wrap"{print $2}')"
fences="$(printf '%s\n'  "$report" | awk -F'\t' '$1=="fence"{print $2}')"
indents="$(printf '%s\n' "$report" | awk -F'\t' '$1=="indent"{print $2}')"

{
    echo "Report-formatting violation in ${file}:"
    if [ -n "$wrapped" ]; then
        echo "Hard-wrapped prose:"
        echo "$wrapped"
    fi
    if [ -n "$fences" ]; then
        echo "Code blocks:"
        echo "$fences"
    fi
    if [ -n "$indents" ]; then
        echo "Indentation:"
        echo "$indents"
    fi
    echo
    if [ -n "$wrapped" ]; then
        echo "AGENTS.md (§ Report formatting): report prose must be copy-paste-ready"
        echo "and must NEVER be hard-wrapped mid-sentence. Rewrite each flagged"
        echo "paragraph as ONE continuous line — keep newlines only between"
        echo "paragraphs, list items, and table rows."
    fi
    if [ -n "$fences" ]; then
        [ -n "$wrapped" ] && echo
        echo "AGENTS.md (§ Report formatting): every fenced code block must open with"
        echo "a language — \`\`\`sh, \`\`\`http, \`\`\`json, \`\`\`text when nothing else fits."
    fi
    if [ -n "$indents" ]; then
        { [ -n "$wrapped" ] || [ -n "$fences" ]; } && echo
        echo "AGENTS.md (§ Report formatting): report Markdown is NEVER indented. The"
        echo "only exception is a nested list item, and it is indented with spaces,"
        echo "never a tab. Everything else starts at column 0 — code fences, prose,"
        echo "tables — including the content that belongs to a list item."
    fi
} >&2
exit 2
