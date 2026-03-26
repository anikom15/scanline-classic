"""
Shader formatting linter for Scanline Classic.

Targets specialized RetroArch shader sources (.slang, .inc) and enforces a
focused style baseline:
- Trailing whitespace is forbidden.
- Tab characters are forbidden (spaces-only indentation/style).
- More than 2 consecutive blank lines is forbidden.
- Control-flow blocks use K&R opening braces: if/else/for/while/switch/do.
- Files must end with a trailing newline.
- Unused includes: in strict mode, direct #include directives whose exported
  symbols are not referenced by the host file are flagged (exempt: menu shaders).

Notes:
- Function declarations and shader declaration blocks (layout/uniform/struct)
  are intentionally not brace-style enforced because this codebase uses
  shader-specific patterns that differ from strict C-style formatting.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SHADER_DIR = ROOT / "shaders"
OPTIONS_SKELETON_PATH = ROOT / "config" / "options.skel.cfg"
SHADER_EXTENSIONS = {".slang", ".inc"}

CONTROL_PATTERN = re.compile(r"^\s*(if|for|while|switch)\b")
ELSE_PATTERN = re.compile(r"^\s*else\b")
DO_PATTERN = re.compile(r"^\s*do\b")
PRAGMA_PARAMETER_PATTERN = re.compile(r"^\s*#pragma\s+parameter\b")
PUSH_LAYOUT_PATTERN = re.compile(r"layout\s*\(\s*push_constant\s*\)\s*uniform\b")
UBO_LAYOUT_PATTERN = re.compile(r"layout\s*\(\s*std140\b[^)]*\)\s*uniform\b")
CONFIG_DEFINE_PATTERN = re.compile(r"^\s*#define\s+\w+\s+config\.(\w+)\b")
GLOBAL_DEFINE_PATTERN = re.compile(r"^\s*#define\s+\w+\s+global\.(\w+)\b")
CONFIG_DEFINE_FULL_PATTERN = re.compile(r"^\s*#define\s+(\w+)\s+config\.(\w+)\b")
GLOBAL_DEFINE_FULL_PATTERN = re.compile(r"^\s*#define\s+(\w+)\s+global\.(\w+)\b")
BLOCK_MEMBER_PATTERN = re.compile(
    r"^\s*(?:layout\s*\([^)]*\)\s*)?"
    r"(?P<type>[A-Za-z_]\w*)\s+"
    r"(?P<name>[A-Za-z_]\w*)"
    r"\s*(?:\[\s*(?P<count>\d+)\s*\])?\s*;"
)
COMMENT_BLOCK_PATTERN = re.compile(r"/\*.*?\*/", re.DOTALL)
STAGE_PATTERN = re.compile(r"^\s*#pragma\s+stage\s+(vertex|fragment)\b")
INCLUDE_PATTERN = re.compile(r'^\s*#include\s+"([^"]+)"')
ALLOW_STAGE_LOCAL_DIRECTIVE = "lint: allow-stage-local"
ALLOW_UNUSED_INCLUDE_DIRECTIVE = "lint: allow-unused-include"
PRAGMA_PARAMETER_SYMBOL_PATTERN = re.compile(r'^\s*#pragma\s+parameter\s+(\w+)\b')
DEFINE_EXPORT_PATTERN = re.compile(r'^\s*#define\s+(\w+)\b')
PREPROCESSOR_CHECK_PATTERN = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif)\b")
OPTION_TOKEN_PATTERN = re.compile(r"\bOPTION_[A-Za-z0-9_]+\b")
OPTION_DEFINE_PATTERN = re.compile(r"^\s*(?://\s*)?#\s*define\s+(OPTION_[A-Za-z0-9_]+)\b")
INCLUDE_OPTIONS_CFG_PATTERN = re.compile(r'^\s*#pragma\s+include_optional\s+"\.\./config/options\.cfg"\s*$')
VARIABLE_DECL_PATTERN = re.compile(
    r"^\s*(?:const\s+)?[A-Za-z_]\w*\s+([A-Za-z_]\w*)\s*(?:\[[^\]]+\])?\s*(?:=[^;]*)?;\s*$"
)
VERSION_PATTERN = re.compile(r"^\s*#version\b")
PRAGMA_NAME_PATTERN = re.compile(r"^\s*#pragma\s+name\b")
PRAGMA_FORMAT_PATTERN = re.compile(r"^\s*#pragma\s+format\b")
FILENAME_COMMENT_PATTERN = re.compile(r"^\s*//\s*Filename:\s*(?P<filename>[^\s]+)\s*$")
COPYRIGHT_START_PATTERN = re.compile(r"^\s*//\s*Copyright\b")


def load_valid_options_from_skeleton(path: Path) -> set[str]:
    if not path.exists() or not path.is_file():
        return set()

    options: set[str] = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        match = OPTION_DEFINE_PATTERN.match(raw_line)
        if match:
            options.add(match.group(1))
    return options


VALID_OPTIONS = load_valid_options_from_skeleton(OPTIONS_SKELETON_PATH)


@dataclass(frozen=True)
class LintIssue:
    path: Path
    line: int
    message: str


@dataclass(frozen=True)
class BlockMember:
    line: int
    type_name: str
    name: str
    array_count: int
    conditional: bool
    option_debug_conditional: bool


@dataclass(frozen=True)
class UniformBlock:
    start_line: int
    end_line: int
    block_name: str
    instance_name: str
    members: list[BlockMember]


@dataclass(frozen=True)
class UniversalSymbol:
    name: str
    line: int
    kind: str
    definition_text: str


def iter_shader_files(root: Path) -> list[Path]:
    return sorted(
        path for path in root.rglob("*") if path.is_file() and path.suffix.lower() in SHADER_EXTENSIONS
    )


def strip_comments_lines(lines: list[str]) -> list[str]:
    stripped_lines: list[str] = []
    in_block_comment = False

    for line in lines:
        out: list[str] = []
        idx = 0
        while idx < len(line):
            if in_block_comment:
                end = line.find("*/", idx)
                if end == -1:
                    idx = len(line)
                else:
                    in_block_comment = False
                    idx = end + 2
                continue

            if line.startswith("/*", idx):
                in_block_comment = True
                idx += 2
                continue

            if line.startswith("//", idx):
                break

            out.append(line[idx])
            idx += 1

        stripped_lines.append("".join(out))

    return stripped_lines


def has_word(text: str, word: str) -> bool:
    return re.search(rf"\b{re.escape(word)}\b", text) is not None


def collect_universal_symbols(lines: list[str], universal_end_idx: int) -> list[UniversalSymbol]:
    if universal_end_idx <= 0:
        return []

    scoped_lines = strip_comments_lines(lines[:universal_end_idx])
    symbols: list[UniversalSymbol] = []
    seen: set[str] = set()
    depth = 0
    idx = 0

    while idx < len(scoped_lines):
        clean_line = scoped_lines[idx]
        stripped = clean_line.strip()

        if depth == 0 and stripped and not stripped.startswith("#"):
            if "(" in stripped and not stripped.startswith(("if", "for", "while", "switch", "return")):
                sig_end = idx
                sig_lines = [scoped_lines[sig_end]]
                sig_text = " ".join(line.strip() for line in sig_lines)
                while (
                    sig_end + 1 < len(scoped_lines)
                    and ")" not in sig_text
                    and ";" not in sig_text
                    and "#" not in sig_text
                ):
                    sig_end += 1
                    sig_lines.append(scoped_lines[sig_end])
                    sig_text = " ".join(line.strip() for line in sig_lines)

                if ")" in sig_text and not sig_text.lstrip().startswith("#"):
                    prefix = sig_text.split("(", 1)[0].strip()
                    if prefix and "=" not in prefix:
                        parts = prefix.split()
                        name = parts[-1] if parts else ""
                        if re.fullmatch(r"[A-Za-z_]\w*", name) and name not in {"if", "for", "while", "switch"}:
                            start_idx = idx
                            end_idx = sig_end

                            body_start = None
                            for probe in range(start_idx, sig_end + 1):
                                if "{" in scoped_lines[probe]:
                                    body_start = probe
                                    break

                            if body_start is None:
                                nxt = find_next_significant(scoped_lines, sig_end + 1)
                                if nxt and nxt[1].strip() == "{":
                                    body_start = nxt[0]

                            if body_start is not None:
                                end_idx = body_start
                                local_depth = scoped_lines[body_start].count("{") - scoped_lines[body_start].count("}")
                                while local_depth > 0 and end_idx + 1 < len(scoped_lines):
                                    end_idx += 1
                                    local_depth += scoped_lines[end_idx].count("{") - scoped_lines[end_idx].count("}")

                            definition = "\n".join(scoped_lines[start_idx : end_idx + 1])
                            if name not in seen:
                                symbols.append(
                                    UniversalSymbol(name=name, line=start_idx + 1, kind="function", definition_text=definition)
                                )
                                seen.add(name)
                            idx = end_idx + 1
                            depth = 0
                            continue

            if not stripped.startswith(("layout", "struct", "uniform", "in ", "out ", "inout ")):
                var_match = VARIABLE_DECL_PATTERN.match(stripped)
                if var_match:
                    name = var_match.group(1)
                    if name not in seen:
                        symbols.append(
                            UniversalSymbol(name=name, line=idx + 1, kind="variable", definition_text=clean_line)
                        )
                        seen.add(name)

        depth = max(0, depth + clean_line.count("{") - clean_line.count("}"))
        idx += 1

    return symbols


def resolve_shader_include_path(parent_file: Path, include_target: str) -> Path | None:
    include_path = Path(include_target)
    candidates = [
        (parent_file.parent / include_path).resolve(),
        (DEFAULT_SHADER_DIR / include_path).resolve(),
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file() and candidate.suffix.lower() in SHADER_EXTENSIONS:
            return candidate

    return None


def collect_effective_stage_markers(
    path: Path,
    lines: list[str],
    visited_stack: set[Path] | None = None,
) -> list[tuple[Path, int, str]]:
    stack = visited_stack or set()
    if path in stack:
        return []

    stack.add(path)
    markers: list[tuple[Path, int, str]] = []

    for idx, line in enumerate(lines):
        stage_match = STAGE_PATTERN.match(line)
        if stage_match:
            markers.append((path, idx + 1, stage_match.group(1)))

        include_match = INCLUDE_PATTERN.match(line)
        if not include_match:
            continue

        include_target = include_match.group(1)
        include_path = resolve_shader_include_path(path, include_target)
        if include_path is None:
            continue

        include_lines = include_path.read_text(encoding="utf-8").splitlines()
        markers.extend(collect_effective_stage_markers(include_path, include_lines, stack))

    stack.remove(path)
    return markers


def check_shader_stage_flow(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    stage_markers: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        stage_match = STAGE_PATTERN.match(line)
        if stage_match:
            stage_markers.append((idx + 1, stage_match.group(1)))

    ext = path.suffix.lower()

    if ext == ".inc":
        for line_no, stage in stage_markers:
            issues.append(
                LintIssue(
                    path=path,
                    line=line_no,
                    message=f"Invalid stage declaration in include file: '#pragma stage {stage}' is not allowed in .inc files",
                )
            )
        return

    if ext != ".slang":
        return

    effective_markers = collect_effective_stage_markers(path, lines)
    effective_vertex = [(p, line) for p, line, stage in effective_markers if stage == "vertex"]
    effective_fragment = [(p, line) for p, line, stage in effective_markers if stage == "fragment"]

    if len(effective_vertex) != 1:
        line_hint = effective_vertex[0][1] if effective_vertex and effective_vertex[0][0] == path else 1
        issues.append(
            LintIssue(
                path=path,
                line=line_hint,
                message=(
                    "Shader flow violation: expected exactly 1 vertex shader section "
                    f"after include expansion, found {len(effective_vertex)}"
                ),
            )
        )

    if len(effective_fragment) != 1:
        line_hint = effective_fragment[0][1] if effective_fragment and effective_fragment[0][0] == path else 1
        issues.append(
            LintIssue(
                path=path,
                line=line_hint,
                message=(
                    "Shader flow violation: expected exactly 1 fragment shader section "
                    f"after include expansion, found {len(effective_fragment)}"
                ),
            )
        )

    if len(effective_vertex) != 1 or len(effective_fragment) != 1:
        return

    # Wrapper shaders may intentionally contribute no local stage declarations,
    # relying on included shader files to provide the full stage flow.
    if not stage_markers:
        return

    vertex_lines = [line for line, stage in stage_markers if stage == "vertex"]
    fragment_lines = [line for line, stage in stage_markers if stage == "fragment"]
    if len(vertex_lines) != 1 or len(fragment_lines) != 1:
        return

    vertex_line = vertex_lines[0]
    fragment_line = fragment_lines[0]

    if vertex_line > fragment_line:
        issues.append(
            LintIssue(
                path=path,
                line=vertex_line,
                message="Shader flow violation: vertex shader section must appear before fragment shader section",
            )
        )
        return

    cleaned_lines = strip_comments_lines(lines)
    vertex_text = "\n".join(cleaned_lines[vertex_line: fragment_line - 1])
    fragment_text = "\n".join(cleaned_lines[fragment_line:])

    universal_symbols = collect_universal_symbols(lines, universal_end_idx=vertex_line - 1)
    symbol_by_name = {symbol.name: symbol for symbol in universal_symbols}
    refs: dict[str, set[str]] = {}
    for symbol in universal_symbols:
        dependencies: set[str] = set()
        for candidate_name in symbol_by_name:
            if candidate_name == symbol.name:
                continue
            if has_word(symbol.definition_text, candidate_name):
                dependencies.add(candidate_name)
        refs[symbol.name] = dependencies

    used_in_vertex = {symbol.name for symbol in universal_symbols if has_word(vertex_text, symbol.name)}
    used_in_fragment = {symbol.name for symbol in universal_symbols if has_word(fragment_text, symbol.name)}

    changed = True
    while changed:
        changed = False
        for name in list(used_in_vertex):
            for dep in refs.get(name, set()):
                if dep not in used_in_vertex:
                    used_in_vertex.add(dep)
                    changed = True
        for name in list(used_in_fragment):
            for dep in refs.get(name, set()):
                if dep not in used_in_fragment:
                    used_in_fragment.add(dep)
                    changed = True

    for symbol in universal_symbols:
        in_vertex = symbol.name in used_in_vertex
        in_fragment = symbol.name in used_in_fragment
        if in_vertex and in_fragment:
            continue

        directive_start = max(0, symbol.line - 3)
        directive_end = min(len(lines), symbol.line)
        directive_window = "\n".join(lines[directive_start:directive_end]).lower()
        if ALLOW_STAGE_LOCAL_DIRECTIVE in directive_window:
            continue

        if in_vertex:
            where = "vertex"
        elif in_fragment:
            where = "fragment"
        else:
            where = "neither"

        issues.append(
            LintIssue(
                path=path,
                line=symbol.line,
                message=(
                    "Universal declaration usage violation: "
                    f"{symbol.kind} '{symbol.name}' is used in {where} section only; "
                    "move it to the appropriate shader section unless it is truly shared by both"
                ),
            )
        )


def find_next_significant(lines: list[str], start_index: int) -> tuple[int, str] | None:
    for idx in range(start_index, len(lines)):
        stripped = lines[idx].strip()
        if not stripped:
            continue
        if stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            continue
        if stripped.startswith("*"):
            continue
        return idx, lines[idx]
    return None


def leading_indent_segment(line: str) -> str:
    match = re.match(r"^[ \t]+", line)
    return match.group(0) if match else ""


def align_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        return value
    return ((value + alignment - 1) // alignment) * alignment


def base_scalar_size(type_name: str) -> int | None:
    if type_name in {"bool", "int", "uint", "float"}:
        return 4
    if type_name in {"double", "int64_t", "uint64_t", "int64", "uint64"}:
        return 8
    return None


def std430_type_layout(type_name: str) -> tuple[int, int] | None:
    scalar = base_scalar_size(type_name)
    if scalar is not None:
        return scalar, scalar

    vec_match = re.fullmatch(r"([biud]?vec)([2-4])", type_name)
    if vec_match:
        count = int(vec_match.group(2))
        comp_size = 8 if vec_match.group(1).startswith("d") else 4
        if count == 2:
            return 2 * comp_size, 2 * comp_size
        if count == 3:
            return 4 * comp_size, 3 * comp_size
        return 4 * comp_size, 4 * comp_size

    mat_match = re.fullmatch(r"(d?mat)([2-4])(?:x([2-4]))?", type_name)
    if mat_match:
        columns = int(mat_match.group(2))
        rows = int(mat_match.group(3) or mat_match.group(2))
        comp_size = 8 if mat_match.group(1).startswith("d") else 4
        vec_align = 2 * comp_size if rows == 2 else 4 * comp_size
        vec_size = rows * comp_size
        stride = align_up(vec_size, vec_align)
        return vec_align, columns * stride

    return None


def member_layout(type_name: str, array_count: int) -> tuple[int, int] | None:
    base = std430_type_layout(type_name)
    if base is None:
        return None
    base_align, base_size = base
    if array_count <= 1:
        return base_align, base_size
    stride = align_up(base_size, base_align)
    return base_align, array_count * stride


def block_size_bytes(members: list[BlockMember], include_conditional: bool) -> int | None:
    offset = 0
    max_align = 1
    for member in members:
        if member.conditional and not include_conditional:
            continue
        layout = member_layout(member.type_name, member.array_count)
        if layout is None:
            return None
        align, size = layout
        max_align = max(max_align, align)
        offset = align_up(offset, align)
        offset += size
    return align_up(offset, max_align)


def strip_inline_comments(line: str) -> str:
    no_block = COMMENT_BLOCK_PATTERN.sub("", line)
    if "//" in no_block:
        no_block = no_block.split("//", 1)[0]
    return no_block


def parse_uniform_block(lines: list[str], start_idx: int) -> UniformBlock | None:
    start_line = start_idx + 1
    header_line = lines[start_idx]
    block_name_match = re.search(r"uniform\s+(\w+)\b", header_line)
    block_name = block_name_match.group(1) if block_name_match else ""

    idx = start_idx
    while idx < len(lines) and "{" not in lines[idx]:
        idx += 1
    if idx >= len(lines):
        return None

    depth = 0
    in_block = False
    preproc_depth = 0
    preproc_option_debug_stack: list[bool] = []
    members: list[BlockMember] = []
    end_idx = idx
    instance_name = ""

    for line_idx in range(idx, len(lines)):
        line = lines[line_idx]

        stripped_line = line.strip()
        if stripped_line.startswith("#if") or stripped_line.startswith("#ifdef") or stripped_line.startswith("#ifndef"):
            preproc_depth += 1
            preproc_option_debug_stack.append("OPTION_DEBUG" in stripped_line)
        elif stripped_line.startswith("#elif"):
            if preproc_option_debug_stack:
                preproc_option_debug_stack[-1] = preproc_option_debug_stack[-1] or ("OPTION_DEBUG" in stripped_line)
        elif stripped_line.startswith("#else"):
            # Keep the same conditional lineage: an #else branch is still part of
            # the same preprocessor region that may be keyed by OPTION_DEBUG.
            pass
        elif stripped_line.startswith("#endif"):
            preproc_depth = max(0, preproc_depth - 1)
            if preproc_option_debug_stack:
                preproc_option_debug_stack.pop()

        clean = strip_inline_comments(line)
        opens = clean.count("{")
        closes = clean.count("}")

        if opens > 0:
            depth += opens
            in_block = True

        if in_block and depth == 1:
            member_match = BLOCK_MEMBER_PATTERN.match(clean)
            if member_match:
                members.append(
                    BlockMember(
                        line=line_idx + 1,
                        type_name=member_match.group("type"),
                        name=member_match.group("name"),
                        array_count=int(member_match.group("count") or 1),
                        conditional=preproc_depth > 0,
                        option_debug_conditional=any(preproc_option_debug_stack),
                    )
                )

        if closes > 0:
            depth -= closes
            if in_block and depth <= 0:
                end_idx = line_idx
                tail = clean.split("}", 1)[1]
                instance_match = re.search(r"\b(\w+)\s*;", tail)
                if instance_match:
                    instance_name = instance_match.group(1)
                else:
                    look_ahead = line_idx + 1
                    while look_ahead < len(lines):
                        nxt = strip_inline_comments(lines[look_ahead]).strip()
                        if not nxt:
                            look_ahead += 1
                            continue
                        instance_match = re.search(r"\b(\w+)\s*;", nxt)
                        if instance_match:
                            instance_name = instance_match.group(1)
                        break
                break

    return UniformBlock(
        start_line=start_line,
        end_line=end_idx + 1,
        block_name=block_name,
        instance_name=instance_name,
        members=members,
    )


def pick_members_to_fill_gap(members: list[tuple[str, int]], gap: int) -> tuple[int, list[tuple[str, int]]]:
    if gap <= 0 or not members:
        return 0, []

    dp: list[tuple[int, int] | None] = [None] * (gap + 1)
    dp[0] = (-1, -1)
    for idx, (_, size) in enumerate(members):
        for total in range(gap, size - 1, -1):
            if dp[total] is None and dp[total - size] is not None:
                dp[total] = (total - size, idx)

    best = max((i for i, state in enumerate(dp) if state is not None), default=0)
    chosen: list[tuple[str, int]] = []
    cur = best
    while cur > 0 and dp[cur] is not None:
        prev, member_idx = dp[cur]
        if member_idx < 0:
            break
        chosen.append(members[member_idx])
        cur = prev
    chosen.reverse()
    return best, chosen


def extract_stage_texts(lines: list[str]) -> tuple[str, str]:
    """Extract vertex and fragment section texts for stage-usage analysis.

    Returns (vertex_text, fragment_text); both empty strings if stage markers
    cannot be resolved to a clean single-vertex + single-fragment layout.
    """
    stage_markers: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        stage_match = STAGE_PATTERN.match(line)
        if stage_match:
            stage_markers.append((idx + 1, stage_match.group(1)))

    vertex_lines = [ln for ln, stage in stage_markers if stage == "vertex"]
    fragment_lines = [ln for ln, stage in stage_markers if stage == "fragment"]
    if len(vertex_lines) != 1 or len(fragment_lines) != 1:
        return "", ""

    vertex_line = vertex_lines[0]
    fragment_line = fragment_lines[0]
    if vertex_line >= fragment_line:
        return "", ""

    cleaned = strip_comments_lines(lines)
    vertex_text = "\n".join(cleaned[vertex_line : fragment_line - 1])
    fragment_text = "\n".join(cleaned[fragment_line:])
    return vertex_text, fragment_text


def member_stage_usage(member_name: str, vertex_text: str, fragment_text: str) -> str:
    """Classify which shader stage(s) a member name appears in.

    Returns 'fragment', 'vertex', 'both', or 'none'.
    """
    in_vertex = bool(vertex_text) and has_word(vertex_text, member_name)
    in_fragment = bool(fragment_text) and has_word(fragment_text, member_name)
    if in_vertex and in_fragment:
        return "both"
    if in_fragment:
        return "fragment"
    if in_vertex:
        return "vertex"
    return "none"


# Stage-priority order for push-block placement: fragment-stage constants should
# occupy push block first since they run every pixel and benefit most from the
# lower-latency push-constant path.
_STAGE_PRIORITY: dict[str, int] = {"fragment": 0, "both": 1, "vertex": 2, "none": 3}


def rough_complexity_score(member_name: str, fragment_text: str) -> tuple[int, str]:
    """Estimate importance from rough fragment-stage usage complexity.

    Returns (score, class_label) where class_label is a rough O-notation style
    bucket used for diagnostics: O(n)-hot, O(1)-hot, O(1), or O(0).
    """
    if not fragment_text.strip():
        return 0, "O(0)"

    lines = fragment_text.splitlines()
    hits = 0
    loop_prox_hits = 0
    op_hits = 0
    call_hits = 0

    loop_window = 0
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            loop_window = max(0, loop_window - 1)
            continue

        if re.search(r"\b(for|while)\b", line):
            loop_window = 4
        else:
            loop_window = max(0, loop_window - 1)

        if not has_word(line, member_name):
            continue

        hits += 1
        if loop_window > 0:
            loop_prox_hits += 1
        if re.search(r"[*/+-]", line):
            op_hits += 1
        if "(" in line and ")" in line:
            call_hits += 1

    score = (hits * 3) + (loop_prox_hits * 8) + (op_hits * 2) + (call_hits * 1)
    if loop_prox_hits > 0:
        return score, "O(n)-hot"
    if hits > 0 and (op_hits > 0 or call_hits > 1):
        return score, "O(1)-hot"
    if hits > 0:
        return score, "O(1)"
    return 0, "O(0)"


def stage_base_priority(usage: str) -> int:
    if usage == "fragment":
        return 700
    if usage == "both":
        return 450
    if usage == "vertex":
        return 120
    return 0


def choose_candidates_by_priority_budget(
    candidates: list[tuple[str, int, str, bool]],
    budget: int,
    fragment_text: str,
) -> tuple[list[tuple[str, int, str, bool, str]], list[tuple[str, int, str, bool, str]]]:
    """Choose a size-constrained candidate set by utility (rough O-analysis).

    Returns (selected, deferred) with each tuple shaped as
    (name, size, usage, option_debug_conditional, complexity_label).
    """
    if budget <= 0 or not candidates:
        return [], [(*c, "O(0)") for c in candidates]

    enriched: list[tuple[str, int, str, bool, int, str]] = []
    for name, size, usage, option_debug in candidates:
        complexity_score, complexity_label = rough_complexity_score(name, fragment_text)
        utility = stage_base_priority(usage) + complexity_score
        if option_debug:
            utility -= 900
        if utility < 0:
            utility = 0
        enriched.append((name, size, usage, option_debug, utility, complexity_label))

    n = len(enriched)
    dp: list[tuple[int, int, int]] = [(-1, -1, -1)] * (budget + 1)
    dp[0] = (0, 0, 0)

    picks: list[list[int]] = [[] for _ in range(budget + 1)]
    for idx, (_, size, _, _, utility, _) in enumerate(enriched):
        for total in range(budget, size - 1, -1):
            prev = dp[total - size]
            if prev[0] < 0:
                continue
            cand_utility = prev[0] + utility
            cand_size = prev[1] + size
            cand_count = prev[2] + 1
            cur = dp[total]
            better = (
                cur[0] < 0
                or cand_utility > cur[0]
                or (cand_utility == cur[0] and cand_size > cur[1])
                or (cand_utility == cur[0] and cand_size == cur[1] and cand_count > cur[2])
            )
            if better:
                dp[total] = (cand_utility, cand_size, cand_count)
                picks[total] = picks[total - size] + [idx]

    best_total = 0
    for total in range(1, budget + 1):
        cur = dp[total]
        best = dp[best_total]
        if (
            cur[0] > best[0]
            or (cur[0] == best[0] and cur[1] > best[1])
            or (cur[0] == best[0] and cur[1] == best[1] and cur[2] > best[2])
        ):
            best_total = total

    selected_idx = set(picks[best_total])
    selected: list[tuple[str, int, str, bool, str]] = []
    deferred: list[tuple[str, int, str, bool, str]] = []
    for idx, (name, size, usage, option_debug, _, complexity_label) in enumerate(enriched):
        item = (name, size, usage, option_debug, complexity_label)
        if idx in selected_idx:
            selected.append(item)
        else:
            deferred.append(item)

    selected.sort(key=lambda x: (1 if x[3] else 0, _STAGE_PRIORITY.get(x[2], 3), x[0]))
    deferred.sort(key=lambda x: (1 if x[3] else 0, _STAGE_PRIORITY.get(x[2], 3), x[0]))
    return selected, deferred


def build_member_define_maps(lines: list[str]) -> tuple[dict[str, tuple[int, str]], dict[str, tuple[int, str]]]:
    """Return define maps keyed by member name for config/global semantic defines.

    Values are (line_index, macro_name).
    """
    config_map: dict[str, tuple[int, str]] = {}
    global_map: dict[str, tuple[int, str]] = {}
    for idx, line in enumerate(lines):
        m_cfg = CONFIG_DEFINE_FULL_PATTERN.match(line)
        if m_cfg:
            macro, member = m_cfg.group(1), m_cfg.group(2)
            config_map[member] = (idx, macro)
            continue
        m_glb = GLOBAL_DEFINE_FULL_PATTERN.match(line)
        if m_glb:
            macro, member = m_glb.group(1), m_glb.group(2)
            global_map[member] = (idx, macro)
    return config_map, global_map


def choose_demotions_for_required_space(
    candidates: list[tuple[str, int, str, bool]],
    required_bytes: int,
    fragment_text: str,
) -> list[tuple[str, int, str, bool]]:
    """Pick low-utility push members to demote until required space is met."""
    if required_bytes <= 0 or not candidates:
        return []

    ranked: list[tuple[str, int, str, bool, int]] = []
    for name, size, usage, option_debug in candidates:
        complexity_score, _ = rough_complexity_score(name, fragment_text)
        utility = stage_base_priority(usage) + complexity_score
        if option_debug:
            utility -= 900
        ranked.append((name, size, usage, option_debug, utility))

    ranked.sort(key=lambda x: (x[4], x[1], x[0]))
    selected: list[tuple[str, int, str, bool]] = []
    total = 0
    for name, size, usage, option_debug, _ in ranked:
        selected.append((name, size, usage, option_debug))
        total += size
        if total >= required_bytes:
            break

    if total < required_bytes:
        return []
    return selected


def auto_fix_header_optional_section_order(path: Path, lines: list[str]) -> tuple[list[str], bool]:
    """Auto-fix optional header section order after copyright block for .slang."""
    if path.suffix.lower() != ".slang" or not lines:
        return lines, False

    version_idx = next((idx for idx, line in enumerate(lines) if VERSION_PATTERN.match(line)), None)
    if version_idx is None:
        return lines, False

    expected_filename_line = version_idx + 2
    separator_idx = expected_filename_line + 1
    if expected_filename_line >= len(lines) or separator_idx >= len(lines):
        return lines, False

    copyright_idx = next((idx for idx, line in enumerate(lines) if COPYRIGHT_START_PATTERN.match(line)), None)
    if copyright_idx is None:
        return lines, False

    section_start = copyright_idx
    while section_start < len(lines) and lines[section_start].lstrip().startswith("//"):
        section_start += 1

    # Gather the optional directive block exactly as check_header_section_order scans.
    idx = section_start
    captured: list[tuple[str, str]] = []
    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        if not stripped:
            idx += 1
            continue

        if PRAGMA_NAME_PATTERN.match(line):
            captured.append(("name", line))
        elif PRAGMA_FORMAT_PATTERN.match(line):
            captured.append(("format", line))
        elif INCLUDE_PATTERN.match(line):
            captured.append(("include", line))
        elif line.lstrip().startswith("#pragma include_optional"):
            captured.append(("include_optional", line))
        elif PRAGMA_PARAMETER_PATTERN.match(line):
            captured.append(("parameter", line))
        else:
            break
        idx += 1

    if not captured:
        return lines, False

    order = ["name", "format", "include", "include_optional", "parameter"]
    grouped: dict[str, list[str]] = {key: [] for key in order}
    for kind, line in captured:
        grouped[kind].append(line)

    reordered: list[str] = []
    for kind in order:
        reordered.extend(grouped[kind])

    original_lines = [line for _, line in captured]
    if reordered == original_lines:
        return lines, False

    # Rewrite only the directive lines in-place; preserve spacing/comments around block.
    new_lines = list(lines)
    write_idx = 0
    for probe in range(section_start, idx):
        line = lines[probe]
        if (
            PRAGMA_NAME_PATTERN.match(line)
            or PRAGMA_FORMAT_PATTERN.match(line)
            or INCLUDE_PATTERN.match(line)
            or line.lstrip().startswith("#pragma include_optional")
            or PRAGMA_PARAMETER_PATTERN.match(line)
        ):
            new_lines[probe] = reordered[write_idx]
            write_idx += 1

    return new_lines, True


def preprocessor_depths(lines: list[str]) -> list[int]:
    """Return active preprocessor conditional depth for each source line."""
    depths: list[int] = []
    depth = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#endif"):
            depth = max(0, depth - 1)

        depths.append(depth)

        if stripped.startswith("#if") or stripped.startswith("#ifdef") or stripped.startswith("#ifndef"):
            depth += 1

    return depths


def lift_insertion_out_of_preprocessor_block(lines: list[str], insert_at: int) -> int:
    """Shift insertion index upward to avoid writing inside #if/#ifdef blocks."""
    if not lines:
        return 0

    idx = max(0, min(insert_at, len(lines)))
    if idx >= len(lines):
        return idx

    depths = preprocessor_depths(lines)
    while idx > 0 and depths[idx] > 0:
        idx -= 1
    return idx


def apply_push_ubo_member_moves(
    lines: list[str],
    push_block: UniformBlock,
    ubo_block: UniformBlock,
    promote_to_push: list[str],
    demote_to_ubo: list[str],
) -> tuple[list[str], bool]:
    """Move declaration lines between push/UBO blocks and rewrite define mappings.

    Only intended for member names that are declaration-backed and define-backed.
    """
    if not promote_to_push and not demote_to_ubo:
        return lines, False

    push_members = {member.name: member for member in push_block.members}
    ubo_members = {member.name: member for member in ubo_block.members}

    remove_indices: set[int] = set()
    insert_before_push_close: list[str] = []
    insert_before_ubo_close: list[str] = []

    for member_name in promote_to_push:
        member = ubo_members.get(member_name)
        if member is None:
            continue
        line_idx = member.line - 1
        if 0 <= line_idx < len(lines):
            remove_indices.add(line_idx)
            insert_before_push_close.append(lines[line_idx])

    for member_name in demote_to_ubo:
        member = push_members.get(member_name)
        if member is None:
            continue
        line_idx = member.line - 1
        if 0 <= line_idx < len(lines):
            remove_indices.add(line_idx)
            insert_before_ubo_close.append(lines[line_idx])

    push_close_idx = push_block.end_line - 1
    ubo_close_idx = ubo_block.end_line - 1

    new_lines: list[str] = []
    changed = False
    for idx, line in enumerate(lines):
        if idx == push_close_idx and insert_before_push_close:
            new_lines.extend(insert_before_push_close)
            changed = True
        if idx == ubo_close_idx and insert_before_ubo_close:
            new_lines.extend(insert_before_ubo_close)
            changed = True
        if idx in remove_indices:
            changed = True
            continue
        new_lines.append(line)

    if not changed:
        return lines, False

    # Rewrite semantic define routing for moved members while keeping section
    # order intact: config.* defines must remain in the config define section
    # and global.* defines must remain in the global define section.
    promote_set = set(promote_to_push)
    demote_set = set(demote_to_ubo)
    remove_define_indices: set[int] = set()
    add_config_defines: list[str] = []
    add_global_defines: list[str] = []

    for idx, line in enumerate(new_lines):
        m_cfg = CONFIG_DEFINE_FULL_PATTERN.match(line)
        if m_cfg and m_cfg.group(2) in demote_set:
            macro, member = m_cfg.group(1), m_cfg.group(2)
            remove_define_indices.add(idx)
            add_global_defines.append(f"#define {macro} global.{member}")
            continue

        m_glb = GLOBAL_DEFINE_FULL_PATTERN.match(line)
        if m_glb and m_glb.group(2) in promote_set:
            macro, member = m_glb.group(1), m_glb.group(2)
            remove_define_indices.add(idx)
            add_config_defines.append(f"#define {macro} config.{member}")
            continue

    compact_lines = [line for idx, line in enumerate(new_lines) if idx not in remove_define_indices]

    # Insert config defines before UBO definition, preferring unconditional
    # config define section and never inside an active preprocessor block.
    if add_config_defines:
        ubo_def_idx = next((i for i, line in enumerate(compact_lines) if UBO_LAYOUT_PATTERN.search(line)), len(compact_lines))
        cfg_candidates = [
            i for i, line in enumerate(compact_lines[:ubo_def_idx]) if CONFIG_DEFINE_FULL_PATTERN.match(line)
        ]
        depths = preprocessor_depths(compact_lines)
        unconditional_cfg = [i for i in cfg_candidates if depths[i] == 0]
        if unconditional_cfg:
            insert_at = unconditional_cfg[-1] + 1
        elif cfg_candidates:
            insert_at = lift_insertion_out_of_preprocessor_block(compact_lines, cfg_candidates[0])
        else:
            insert_at = ubo_def_idx
        compact_lines = compact_lines[:insert_at] + add_config_defines + compact_lines[insert_at:]

    # Insert global defines after UBO definition, preferring unconditional
    # global define section and never inside an active preprocessor block.
    if add_global_defines:
        depths = preprocessor_depths(compact_lines)
        all_global_indices = [
            i for i, line in enumerate(compact_lines) if GLOBAL_DEFINE_FULL_PATTERN.match(line)
        ]
        unconditional_global_idx = next((i for i in all_global_indices if depths[i] == 0), None)
        if unconditional_global_idx is not None:
            insert_at = unconditional_global_idx
        elif all_global_indices:
            insert_at = lift_insertion_out_of_preprocessor_block(compact_lines, all_global_indices[0])
        else:
            ubo_idx = next((i for i, line in enumerate(compact_lines) if UBO_LAYOUT_PATTERN.search(line)), None)
            if ubo_idx is None:
                insert_at = len(compact_lines)
            else:
                ubo_blk = parse_uniform_block(compact_lines, ubo_idx)
                insert_at = ubo_blk.end_line if ubo_blk is not None else (ubo_idx + 1)
            insert_at = lift_insertion_out_of_preprocessor_block(compact_lines, insert_at)
        compact_lines = compact_lines[:insert_at] + add_global_defines + compact_lines[insert_at:]

    # Rewrite direct struct-member references to keep semantics aligned even
    # when a member has no semantic #define alias.
    rewritten_lines: list[str] = []
    for line in compact_lines:
        updated = line
        for member in demote_set:
            updated = re.sub(rf"\bconfig\.{re.escape(member)}\b", f"global.{member}", updated)
        for member in promote_set:
            updated = re.sub(rf"\bglobal\.{re.escape(member)}\b", f"config.{member}", updated)
        rewritten_lines.append(updated)

    return rewritten_lines, True


def structural_autofix_push_ubo(lines: list[str]) -> tuple[list[str], bool]:
    """Autofix push/UBO placement for strict structural performance rules."""
    push_idx = next((idx for idx, line in enumerate(lines) if PUSH_LAYOUT_PATTERN.search(line)), None)
    ubo_idx = next((idx for idx, line in enumerate(lines) if UBO_LAYOUT_PATTERN.search(line)), None)
    if push_idx is None or ubo_idx is None:
        return lines, False

    push_block = parse_uniform_block(lines, push_idx)
    ubo_block = parse_uniform_block(lines, ubo_idx)
    if not push_block or not ubo_block:
        return lines, False

    push_size_max = block_size_bytes(push_block.members, include_conditional=True)
    if push_size_max is None:
        return lines, False

    push_limit = 128
    vertex_text, fragment_text = extract_stage_texts(lines)
    stages_available = bool(vertex_text or fragment_text)
    if not stages_available:
        return lines, False

    def _promotable_ubo_members() -> list[tuple[str, int, str, bool]]:
        out: list[tuple[str, int, str, bool]] = []
        seen: set[str] = set()
        for member in ubo_block.members:
            if member.name == "MVP" or member.name in seen:
                continue
            seen.add(member.name)
            if member.conditional:
                continue
            usage = member_stage_usage(member.name, vertex_text, fragment_text)
            if usage == "none":
                continue
            ly = member_layout(member.type_name, member.array_count)
            if ly is None:
                continue
            out.append((member.name, ly[1], usage, member.option_debug_conditional))
        return out

    def _demotable_push_members() -> list[tuple[str, int, str, bool]]:
        out: list[tuple[str, int, str, bool]] = []
        seen: set[str] = set()
        for member in push_block.members:
            if member.name in seen:
                continue
            seen.add(member.name)
            if member.conditional:
                continue
            usage = member_stage_usage(member.name, vertex_text, fragment_text)
            ly = member_layout(member.type_name, member.array_count)
            if ly is None:
                continue
            out.append((member.name, ly[1], usage, member.option_debug_conditional))
        return out

    changed = False
    working_lines = lines

    if push_size_max < push_limit:
        candidates = _promotable_ubo_members()
        selected, _ = choose_candidates_by_priority_budget(
            candidates,
            budget=push_limit - push_size_max,
            fragment_text=fragment_text,
        )
        promote_names = [name for name, _, _, _, _ in selected]
        if promote_names:
            updated, did_change = apply_push_ubo_member_moves(
                working_lines,
                push_block,
                ubo_block,
                promote_to_push=promote_names,
                demote_to_ubo=[],
            )
            if did_change:
                working_lines = updated
                changed = True

    else:
        promote_candidates = [
            cand for cand in _promotable_ubo_members() if cand[2] == "fragment" and not cand[3]
        ]
        demote_candidates = [
            (n, s, u, d)
            for n, s, u, d in _demotable_push_members()
            if d or u == "vertex"
        ]
        if promote_candidates and demote_candidates:
            max_freed = sum(size for _, size, _, _ in demote_candidates)
            selected_promotions, _ = choose_candidates_by_priority_budget(
                [c for c in promote_candidates if c[1] <= max_freed],
                budget=max_freed,
                fragment_text=fragment_text,
            )
            promote_names = [name for name, _, _, _, _ in selected_promotions]
            required = sum(size for _, size, _, _, _ in selected_promotions)
            selected_demotions = choose_demotions_for_required_space(
                demote_candidates,
                required_bytes=required,
                fragment_text=fragment_text,
            )
            demote_names = [name for name, _, _, _ in selected_demotions]

            if promote_names and demote_names:
                updated, did_change = apply_push_ubo_member_moves(
                    working_lines,
                    push_block,
                    ubo_block,
                    promote_to_push=promote_names,
                    demote_to_ubo=demote_names,
                )
                if did_change:
                    working_lines = updated
                    changed = True

    return working_lines, changed


def check_block_order_and_push_budget(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    section_positions: dict[str, int] = {}

    pragma_lines = [idx + 1 for idx, line in enumerate(lines) if PRAGMA_PARAMETER_PATTERN.search(line)]
    if pragma_lines:
        section_positions["parameter_pragmas"] = pragma_lines[0]

    push_idx = next((idx for idx, line in enumerate(lines) if PUSH_LAYOUT_PATTERN.search(line)), None)
    ubo_idx = next((idx for idx, line in enumerate(lines) if UBO_LAYOUT_PATTERN.search(line)), None)
    config_define_lines = [idx + 1 for idx, line in enumerate(lines) if CONFIG_DEFINE_PATTERN.match(line)]
    global_define_matches = [
        (idx + 1, GLOBAL_DEFINE_PATTERN.match(line).group(1))
        for idx, line in enumerate(lines)
        if GLOBAL_DEFINE_PATTERN.match(line)
    ]

    push_block = parse_uniform_block(lines, push_idx) if push_idx is not None else None
    ubo_block = parse_uniform_block(lines, ubo_idx) if ubo_idx is not None else None

    if push_block:
        section_positions["push_block_definition"] = push_block.start_line
    elif push_idx is not None:
        section_positions["push_block_definition"] = push_idx + 1

    if config_define_lines:
        section_positions["push_block_semantic_defines"] = config_define_lines[0]

    if ubo_block:
        section_positions["ubo_definition"] = ubo_block.start_line
    elif ubo_idx is not None:
        section_positions["ubo_definition"] = ubo_idx + 1

    if global_define_matches:
        section_positions["ubo_semantic_defines"] = global_define_matches[0][0]

    ordered_sections = [
        "parameter_pragmas",
        "push_block_definition",
        "push_block_semantic_defines",
        "ubo_definition",
        "ubo_semantic_defines",
    ]

    prev_name: str | None = None
    prev_line: int | None = None
    pretty_names = {
        "parameter_pragmas": "parameter pragmas",
        "push_block_definition": "push block definition",
        "push_block_semantic_defines": "push block semantic defines",
        "ubo_definition": "UBO definition",
        "ubo_semantic_defines": "UBO semantic defines",
    }

    for section in ordered_sections:
        line_no = section_positions.get(section)
        if line_no is None:
            continue
        if prev_line is not None and line_no < prev_line:
            issues.append(
                LintIssue(
                    path=path,
                    line=line_no,
                    message=(
                        "Section order violation: "
                        f"'{pretty_names[section]}' must appear after '{pretty_names[prev_name]}'"
                    ),
                )
            )
        else:
            prev_name = section
            prev_line = line_no

    if not push_block:
        return

    # Evaluate push-constant budget using maximum possible size across
    # conditional compilation paths, while also reporting a minimum bound.
    push_size_min = block_size_bytes(push_block.members, include_conditional=False)
    push_size_max = block_size_bytes(push_block.members, include_conditional=True)

    if push_size_min is None or push_size_max is None:
        issues.append(
            LintIssue(
                path=path,
                line=push_block.start_line,
                message="Unable to compute push block size due to unsupported push-constant type(s)",
            )
        )
        return

    push_limit = 128
    if push_size_max > push_limit:
        issues.append(
            LintIssue(
                path=path,
                line=push_block.start_line,
                message=(
                    "Push block exceeds 128-byte limit: "
                    f"min={push_size_min}B, max={push_size_max}B"
                ),
            )
        )
        return

    if not ubo_block:
        return

    ubo_non_mvp_semantics = [name for _, name in global_define_matches if name != "MVP"]
    if not ubo_non_mvp_semantics:
        for member in ubo_block.members:
            if member.name != "MVP":
                ubo_non_mvp_semantics.append(member.name)

    # Determine stage texts so that fragment-stage constants get priority for push
    # block space (push constants are faster; fragment runs every pixel).
    vertex_text, fragment_text = extract_stage_texts(lines)
    stages_available = bool(vertex_text or fragment_text)

    # When push block is at capacity, check for suboptimal layout: low-priority
    # push members (OPTION_DEBUG first, then vertex-only) occupying space that
    # higher-priority UBO members could better use.
    if push_size_max >= push_limit:
        if stages_available:
            push_demote_candidates: list[tuple[str, int]] = []
            for member in push_block.members:
                usage = member_stage_usage(member.name, vertex_text, fragment_text)
                demote_candidate = member.option_debug_conditional or usage == "vertex"
                if not demote_candidate:
                    continue
                ly = member_layout(member.type_name, member.array_count)
                if ly is not None:
                    push_demote_candidates.append((member.name, ly[1]))

            if push_demote_candidates:
                seen_swap: set[str] = set()
                ubo_promote_candidates: list[tuple[str, int, str, bool]] = []
                for member in ubo_block.members:
                    if member.name in seen_swap or member.name == "MVP":
                        continue
                    seen_swap.add(member.name)
                    usage = member_stage_usage(member.name, vertex_text, fragment_text)
                    # At-capacity swaps only target true high-priority classes:
                    # non-debug fragment-only constants.
                    if usage != "fragment" or member.option_debug_conditional:
                        continue
                    ly = member_layout(member.type_name, member.array_count)
                    if ly is not None:
                        ubo_promote_candidates.append((member.name, ly[1], usage, member.option_debug_conditional))

                ubo_promote_candidates.sort(key=lambda x: (1 if x[3] else 0, _STAGE_PRIORITY.get(x[2], 3), x[0]))

                if ubo_promote_candidates:
                    freed = sum(size for _, size in push_demote_candidates)
                    promotable = [(n, s, u, dbg) for n, s, u, dbg in ubo_promote_candidates if s <= freed]
                    selected_promotions, deferred_promotions = choose_candidates_by_priority_budget(
                        promotable,
                        budget=freed,
                        fragment_text=fragment_text,
                    )
                    if selected_promotions:
                        demote_list = ", ".join(f"{n}({s}B)" for n, s in push_demote_candidates)
                        promote_list = ", ".join(
                            f"{n}({s}B/{u}{'/debug' if dbg else ''}/{cx})"
                            for n, s, u, dbg, cx in selected_promotions
                        )
                        deferred_note = ""
                        if deferred_promotions:
                            deferred_names = ", ".join(n for n, *_ in deferred_promotions[:6])
                            deferred_note = (
                                f" Deferred due to push-byte budget after rough O analysis: {deferred_names}."
                            )
                        issues.append(
                            LintIssue(
                                path=path,
                                line=push_block.start_line,
                                message=(
                                    "Push block layout suboptimal: push block is at capacity but contains "
                                    "low-priority member(s) while higher-priority UBO member(s) are present; "
                                    f"consider demoting push member(s) ({demote_list}) and promoting UBO member(s) "
                                    f"({promote_list}), with OPTION_DEBUG members treated as lowest priority"
                                    f"{deferred_note}"
                                ),
                            )
                        )
        return

    if not ubo_non_mvp_semantics:
        return

    # Build stage-prioritized candidate list: fragment > both > vertex > none.
    # Fragment-stage constants benefit most from push-block placement and are
    # listed first so the two-phase knapsack selects them preferentially.
    seen_cand: set[str] = set()
    staged_candidates: list[tuple[str, int, str, bool]] = []
    for member in ubo_block.members:
        if member.name == "MVP" or member.name in seen_cand:
            continue
        seen_cand.add(member.name)
        ly = member_layout(member.type_name, member.array_count)
        if ly is None:
            continue
        _, size = ly
        usage = member_stage_usage(member.name, vertex_text, fragment_text) if stages_available else "none"
        staged_candidates.append((member.name, size, usage, member.option_debug_conditional))

    # OPTION_DEBUG constants are always lowest priority regardless of stage.
    staged_candidates.sort(key=lambda x: (1 if x[3] else 0, _STAGE_PRIORITY.get(x[2], 3), x[0]))

    # Budgeted utility selection with rough O-analysis. Fragment-heavy and
    # higher-complexity constants are preferred; OPTION_DEBUG remains lowest.
    remaining = push_limit - push_size_max
    selected_enriched, deferred_enriched = choose_candidates_by_priority_budget(
        staged_candidates,
        budget=remaining,
        fragment_text=fragment_text,
    )
    selected = [(n, s) for n, s, _, _, _ in selected_enriched]
    packed = sum(s for _, s in selected)
    target = push_size_max + packed

    usage_map = {n: u for n, _, u, _ in staged_candidates}
    debug_map = {n: dbg for n, _, _, dbg in staged_candidates}

    def _fmt_candidate(name: str, size: int) -> str:
        u = usage_map.get(name, "none")
        dbg = debug_map.get(name, False)
        if dbg and u != "none":
            tag = f"/{u}/debug"
        elif dbg:
            tag = "/debug"
        elif u != "none":
            tag = f"/{u}"
        else:
            tag = ""
        return f"{name}({size}B{tag})"

    if selected:
        move_list = ", ".join(_fmt_candidate(n, s) for n, s in selected)
        deferred_note = ""
        if deferred_enriched:
            deferred_names = ", ".join(n for n, *_ in deferred_enriched[:6])
            deferred_note = f" Deferred by rough O-priority due to limited push space: {deferred_names}."
        message = (
            "Push block underutilized: "
            f"min={push_size_min}B, max={push_size_max}B (<128B) with non-MVP UBO semantics; "
            f"move candidate(s) from UBO -> push to approach 128B (target {target}B): {move_list}"
            f"{deferred_note}"
        )
    else:
        message = (
            "Push block underutilized: "
            f"min={push_size_min}B, max={push_size_max}B (<128B) with non-MVP UBO semantics; "
            "no fit-to-gap suggestion could be derived from parsed UBO members"
        )

    issues.append(LintIssue(path=path, line=push_block.start_line, message=message))


def check_control_kr_braces(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        control_match = CONTROL_PATTERN.match(line)
        is_else = ELSE_PATTERN.match(line) is not None
        is_do = DO_PATTERN.match(line) is not None
        if not control_match and not is_else and not is_do:
            continue

        if "{" in stripped:
            if re.search(r"\S\{", stripped):
                issues.append(
                    LintIssue(
                        path=path,
                        line=idx + 1,
                        message="K&R brace style: expected a space before '{' in control statement",
                    )
                )
            continue

        nxt = find_next_significant(lines, idx + 1)
        if not nxt:
            continue

        next_idx, next_line = nxt
        if next_line.strip() == "{":
            keyword = "else" if is_else else "do" if is_do else control_match.group(1)
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message=f"K&R brace style: move '{{' onto the same line as '{keyword}'",
                )
            )
            issues.append(
                LintIssue(
                    path=path,
                    line=next_idx + 1,
                    message="Opening brace should not be on a standalone line for control-flow blocks",
                )
            )


def check_options_include_requirement(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    if path.suffix.lower() != ".slang":
        return

    option_lines: list[tuple[int, set[str]]] = []
    for idx, line in enumerate(lines):
        if not PREPROCESSOR_CHECK_PATTERN.match(line):
            continue
        found = set(OPTION_TOKEN_PATTERN.findall(line))
        if found:
            option_lines.append((idx + 1, found))

    if not option_lines:
        return

    include_line = next(
        (idx + 1 for idx, line in enumerate(lines) if INCLUDE_OPTIONS_CFG_PATTERN.match(line)),
        None,
    )

    if include_line is not None:
        first_option_line = option_lines[0][0]
        if include_line > first_option_line:
            issues.append(
                LintIssue(
                    path=path,
                    line=first_option_line,
                    message=(
                        "Options include order violation: "
                        "'#pragma include_optional \"../config/options.cfg\"' "
                        "must appear before any OPTION preprocessor check"
                    ),
                )
            )
        return

    used_options = sorted({name for _, names in option_lines for name in names})
    known_options = [name for name in used_options if name in VALID_OPTIONS]

    if known_options:
        used_desc = ", ".join(known_options)
    else:
        used_desc = ", ".join(used_options)

    issues.append(
        LintIssue(
            path=path,
            line=option_lines[0][0],
            message=(
                "Missing required options include: OPTION preprocessor check(s) detected "
                f"({used_desc}) but file is missing '#pragma include_optional \"../config/options.cfg\"'"
            ),
        )
    )


def check_header_section_order(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    if path.suffix.lower() != ".slang" or not lines:
        return

    version_idx = next((idx for idx, line in enumerate(lines) if VERSION_PATTERN.match(line)), None)
    if version_idx is None:
        return

    expected_filename_line = version_idx + 2
    if expected_filename_line >= len(lines):
        issues.append(
            LintIssue(
                path=path,
                line=version_idx + 1,
                message="Missing filename identifier comment after '#version'",
            )
        )
        return

    filename_match = FILENAME_COMMENT_PATTERN.match(lines[expected_filename_line])
    if filename_match is None:
        issues.append(
            LintIssue(
                path=path,
                line=min(version_idx + 2, len(lines)),
                message="Header order violation: expected '// Filename: <file-name>' immediately after '#version'",
            )
        )
        return

    declared_filename = filename_match.group("filename")
    if declared_filename != path.name:
        issues.append(
            LintIssue(
                path=path,
                line=expected_filename_line + 1,
                message=(
                    "Filename identifier mismatch: "
                    f"expected '// Filename: {path.name}' but found '// Filename: {declared_filename}'"
                ),
            )
        )

    separator_idx = expected_filename_line + 1
    if separator_idx >= len(lines) or lines[separator_idx].strip() != "//":
        issues.append(
            LintIssue(
                path=path,
                line=min(separator_idx + 1, len(lines)),
                message="Header order violation: expected blank comment line '//' after the filename identifier",
            )
        )
        return

    copyright_idx = next((idx for idx, line in enumerate(lines) if COPYRIGHT_START_PATTERN.match(line)), None)
    if copyright_idx is None:
        issues.append(
            LintIssue(
                path=path,
                line=version_idx + 1,
                message="Missing copyright declaration comment block after filename identifier",
            )
        )
        return

    if copyright_idx != separator_idx + 1:
        issues.append(
            LintIssue(
                path=path,
                line=copyright_idx + 1,
                message="Header order violation: copyright block must start immediately after the blank comment line following the filename identifier",
            )
        )

    for idx in range(copyright_idx):
        if idx == version_idx:
            continue
        if idx == expected_filename_line:
            continue
        if idx == separator_idx:
            continue
        stripped = lines[idx].strip()
        if not stripped:
            continue
        if stripped:
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message="Header order violation: only '#version', '// Filename: ...', and a blank comment line may appear above the copyright declaration block",
                )
            )
            break

    section_end = copyright_idx
    while section_end < len(lines) and lines[section_end].lstrip().startswith("//"):
        section_end += 1

    state_order = {
        "name": 0,
        "format": 1,
        "include": 2,
        "include_optional": 3,
        "parameter": 4,
    }
    seen_state = -1

    for idx in range(section_end, len(lines)):
        stripped = lines[idx].strip()
        if not stripped:
            continue

        if PRAGMA_NAME_PATTERN.match(lines[idx]):
            current = state_order["name"]
            label = "#pragma name"
        elif PRAGMA_FORMAT_PATTERN.match(lines[idx]):
            current = state_order["format"]
            label = "#pragma format"
        elif INCLUDE_PATTERN.match(lines[idx]):
            current = state_order["include"]
            label = "#include"
        elif lines[idx].lstrip().startswith("#pragma include_optional"):
            current = state_order["include_optional"]
            label = "#pragma include_optional"
        elif PRAGMA_PARAMETER_PATTERN.match(lines[idx]):
            current = state_order["parameter"]
            label = "#pragma parameter"
        else:
            break

        if current < seen_state:
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message=(
                        "Header section order violation: expected optional sections after copyright block in order "
                        "'#pragma name', '#pragma format', '#include', '#pragma include_optional', '#pragma parameter'"
                    ),
                )
            )
            break

        seen_state = current


def collect_include_exports(include_path: Path) -> set[str]:
    """Return #pragma parameter symbol names exported by an include file.

    Only collects parameter identifiers declared with '#pragma parameter'.
    General #define macros are intentionally excluded: they are often internal
    constants used inside functions defined in the same file and are not
    expected to appear by name in the host shader.
    Does not recurse into transitive includes to keep the check focused.
    Returns an empty set if the file cannot be read.
    """
    try:
        raw_lines = include_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()

    exports: set[str] = set()
    for line in raw_lines:
        m = PRAGMA_PARAMETER_SYMBOL_PATTERN.match(line)
        if m:
            exports.add(m.group(1))
    return exports


def check_unused_includes(path: Path, lines: list[str], issues: list[LintIssue]) -> None:
    """Flag direct #include directives whose exported symbols are not used in the host file.

    Only runs on .slang files outside of the menus/ subdirectory. Menu shaders
    aggregate #pragma parameter directives for RetroArch by design and are exempt.

    A comment containing 'lint: allow-unused-include' on the line immediately
    preceding the include suppresses the diagnostic for that include.
    """
    if path.suffix.lower() != ".slang":
        return

    # Menu shaders include parameter files purely to register #pragma parameters
    # with RetroArch; symbol usage by name is not expected there.
    if any(part == "menus" for part in path.parts):
        return

    cleaned = strip_comments_lines(lines)

    for idx, line in enumerate(lines):
        include_match = INCLUDE_PATTERN.match(line)
        if not include_match:
            continue

        include_target = include_match.group(1)
        include_path = resolve_shader_include_path(path, include_target)
        if include_path is None:
            continue

        # Allow suppression via a directive comment on the preceding line.
        directive_start = max(0, idx - 1)
        directive_window = "\n".join(lines[directive_start : idx + 1]).lower()
        if ALLOW_UNUSED_INCLUDE_DIRECTIVE in directive_window:
            continue

        exports = collect_include_exports(include_path)
        if not exports:
            # No extractable named symbols (e.g. pure stage-flow or struct-only
            # includes); skip to avoid false positives.
            continue

        # Build host text from all lines except the include directive itself.
        host_lines = cleaned[:idx] + cleaned[idx + 1:]
        host_text = "\n".join(host_lines)

        if not any(has_word(host_text, sym) for sym in exports):
            issues.append(
                LintIssue(
                    path=path,
                    line=idx + 1,
                    message=(
                        f"Unused include: '{include_target}' contributes no symbols "
                        "referenced by this file"
                    ),
                )
            )


def lint_one_file(
    path: Path,
    fix: bool,
    strict_structure: bool,
    fix_structure: bool,
    dry_run: bool,
) -> tuple[list[LintIssue], bool]:
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines()
    issues: list[LintIssue] = []
    changed = False

    if fix_structure and strict_structure and path.suffix.lower() == ".slang":
        lines, header_changed = auto_fix_header_optional_section_order(path, lines)
        if header_changed:
            changed = True
        for _ in range(3):
            lines, struct_changed = structural_autofix_push_ubo(lines)
            if not struct_changed:
                break
            changed = True

    fixed_lines: list[str] = []
    blank_run = 0

    for idx, original_line in enumerate(lines):
        line = original_line

        if line.rstrip(" \t") != line:
            if not fix:
                issues.append(LintIssue(path=path, line=idx + 1, message="Trailing whitespace"))
            if fix:
                line = line.rstrip(" \t")

        if "\t" in line:
            if not fix:
                issues.append(
                    LintIssue(
                        path=path,
                        line=idx + 1,
                        message="Tab character found (spaces-only style required)",
                    )
                )
            if fix:
                line = line.replace("\t", "    ")

        if line.strip() == "":
            blank_run += 1
            if blank_run > 2:
                if not fix:
                    issues.append(
                        LintIssue(
                            path=path,
                            line=idx + 1,
                            message="More than 2 consecutive blank lines",
                        )
                    )
                if fix:
                    continue
        else:
            blank_run = 0

        fixed_lines.append(line)

    check_control_kr_braces(path, lines, issues)
    check_options_include_requirement(path, lines, issues)

    if strict_structure:
        check_header_section_order(path, lines, issues)
        check_shader_stage_flow(path, lines, issues)
        check_unused_includes(path, lines, issues)

    if strict_structure and path.suffix.lower() == ".slang":
        check_block_order_and_push_budget(path, lines, issues)

    output_text = "\n".join(fixed_lines)
    if lines:
        output_text += "\n"

    if not raw.endswith("\n"):
        if not fix:
            issues.append(LintIssue(path=path, line=max(1, len(lines)), message="Missing trailing newline at end of file"))
        if fix:
            if not output_text.endswith("\n"):
                output_text += "\n"

    if (fix or fix_structure) and output_text != raw:
        if not dry_run:
            path.write_text(output_text, encoding="utf-8", newline="\n")
        changed = True

    return issues, changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lint shader formatting in shaders/ (*.slang, *.inc)")
    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_SHADER_DIR,
        help="Shader root directory (default: %(default)s)",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Apply safe autofixes (tabs to spaces, trailing whitespace, blank-run reduction, EOF newline)",
    )
    parser.add_argument(
        "--strict-structure",
        action="store_true",
        help="Enable stricter shader-structure checks (stage flow, universal declarations, push/UBO ordering/budget, unused includes)",
    )
    parser.add_argument(
        "--fix-structure",
        action="store_true",
        help=(
            "Apply structural autofixes for push/UBO placement in strict mode "
            "using fragment-priority + rough complexity scoring"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes for any fix mode without writing files",
    )
    parser.add_argument(
        "--max-errors",
        type=int,
        default=200,
        help="Maximum number of errors to print (default: %(default)s)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()

    if not root.exists() or not root.is_dir():
        print(f"Error: shader root not found or not a directory: {root}", file=sys.stderr)
        return 2

    files = iter_shader_files(root)
    if not files:
        print(f"No shader files found under {root}")
        return 0

    all_issues: list[LintIssue] = []
    changed_files = 0
    changed_paths: list[Path] = []
    for path in files:
        issues, changed = lint_one_file(
            path,
            fix=args.fix,
            strict_structure=args.strict_structure,
            fix_structure=args.fix_structure,
            dry_run=args.dry_run,
        )
        all_issues.extend(issues)
        if changed:
            changed_files += 1
            changed_paths.append(path)

    for issue in all_issues[: args.max_errors]:
        rel = issue.path.relative_to(ROOT)
        print(f"{rel}:{issue.line}: {issue.message}")

    if len(all_issues) > args.max_errors:
        print(f"... {len(all_issues) - args.max_errors} more issue(s) not shown")

    checked_count = len(files)
    fix_mode_active = args.fix or args.fix_structure

    def _print_dry_run_changed_list() -> None:
        if not args.dry_run or not fix_mode_active or not changed_paths:
            return
        print("Files that would be modified:")
        for path in changed_paths:
            rel = path.relative_to(ROOT)
            print(f"  - {rel}")

    if all_issues:
        print(f"\nLint failed: {len(all_issues)} issue(s) across {checked_count} file(s).")
        if fix_mode_active:
            if args.dry_run:
                print(f"Dry run: {changed_files} file(s) would be autofixed.")
                _print_dry_run_changed_list()
            else:
                print(f"Autofixed {changed_files} file(s) where safe fixes were possible.")
        return 1

    print(f"Lint passed: checked {checked_count} file(s).")
    if fix_mode_active:
        if args.dry_run:
            print(f"Dry run: {changed_files} file(s) would be autofixed.")
            _print_dry_run_changed_list()
        else:
            print(f"Autofixed {changed_files} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
